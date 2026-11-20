import Foundation
import ToolsyEngine
import ToolsyShared

/// `preview`: what a mod's quick controls, page and widgets show for a state, as a stable indented outline. It
/// follows the rules of MOD_FORMAT.md "Interface", "Widgets" and "Quick controls" as the app renders them, and runs
/// nothing.
struct PreviewCommand {
    let package: URL
    let stateChanges: ModState
    let language: String?

    init(_ arguments: Arguments) throws(UsageError) {
        package = absolute(try arguments.positionals(1...1, "a mod folder")[0])
        guard let changes = (try arguments.json("--state") ?? [:]).objectValue else {
            throw UsageError(message: "--state must be a JSON object", command: "preview")
        }
        if let key = changes.keys.sorted().first(where: { !ModManifest.isValidKey($0) }) {
            throw UsageError(message: "--state: \"\(key)\" is not a valid state key", command: "preview")
        }
        stateChanges = changes
        language = arguments.value("--language")
    }

    func run() async throws -> Int32 {
        var manifest = try await ModPackage.validate(package)
        if let language {
            guard manifest.localizationCode(for: [language]) != nil else {
                let known = manifest.localizations.keys.sorted().joined(separator: ", ")
                throw UsageError(message: "--language: \(manifest.id) has no localization for \"\(language)\"; it has: \(known.isEmpty ? "none" : known)", command: "preview")
            }
            manifest = manifest.localized(for: [language])
        }
        var state = manifest.settings
        state[ReservedStateKey.enabled] = false
        for (key, value) in stateChanges {
            state[key] = value == .null ? JSONValue?.none : value
        }
        print(Outline(manifest: manifest, state: state, language: language).text)
        return 0
    }
}

/// The lines of a preview. Text is quoted as JSON, so empty and whitespace-only text is visible.
private struct Outline {
    let manifest: ModManifest
    let state: ModState
    private(set) var lines: [String] = []
    /// The controls being added are quick controls.
    private var isQuick = false

    init(manifest: ModManifest, state: ModState, language: String?) {
        self.manifest = manifest
        self.state = state
        add(0, "\(manifest.name) \(manifest.version) (\(manifest.id))" + (language.map { ", language \($0)" } ?? ""))
        if manifest.lifecycle.hasToggle {
            add(0, "switch: \(state[ReservedStateKey.enabled]?.boolValue == true ? "on" : "off")")
        }
        add(0, attention)
        if !manifest.quick.isEmpty {
            add(0, "quick:")
            isQuick = true
            manifest.quick.forEach { add($0, depth: 1) }
            isQuick = false
        }
        add(0, "page:")
        if manifest.ui.isEmpty {
            add(1, "no controls: Toolsy shows the status and the summary")
        }
        manifest.ui.forEach { add($0, depth: 1) }
        add(0, manifest.widgets.isEmpty ? "widgets: none" : "widgets:")
        for widget in manifest.widgets {
            add(widget)
        }
    }

    var text: String { lines.joined(separator: "\n") }

    private mutating func add(_ depth: Int, _ line: String) {
        lines.append(String(repeating: "  ", count: depth) + line)
    }

    // MARK: - State

    private func render(_ template: String) -> String {
        // As `Mod.render`: manifests are validated, so their templates parse; other text stays as is.
        (try? ModTemplate(template))?.render(state) ?? template
    }

    private func holds(_ expression: String) -> Bool {
        // As `Mod.evaluate`: validated expressions parse; anything else counts as false.
        (try? ModExpression(expression))?.evaluate(state) ?? false
    }

    /// The JSON of a state key's value, or `missing`.
    private func bound(_ key: String) -> String {
        state[key].map { "bind \(key) = \($0.compactJSON)" } ?? "bind \(key) missing"
    }

    private static func quoted(_ text: String) -> String {
        JSONValue.string(text).compactJSON
    }

    private static func number(_ value: Double) -> String {
        JSONValue.number(value).text
    }

    /// The keys Toolsy draws attention with: the status line, its colour and the error.
    private var attention: String {
        let parts = [ReservedStateKey.status, ReservedStateKey.level, ReservedStateKey.error].map { key in
            guard let value = state[key] else { return "\(key): none" }
            let invalid = switch key {
            case ReservedStateKey.level: value.stringValue.flatMap(ModLevel.init(rawValue:)) == nil ? " (not ok, warn, error or off: ignored)" : ""
            default: value.stringValue == nil ? " (not text: not shown)" : ""
            }
            return "\(key): \(value.compactJSON)\(invalid)"
        }
        return parts.joined(separator: ", ")
    }

    /// A rendered `tint`, flagged when it names no colour (the app then keeps its default).
    private func tint(_ template: String?) -> String? {
        guard let template else { return nil }
        let rendered = render(template)
        let name = rendered.trimmingCharacters(in: .whitespaces).lowercased()
        guard !name.isEmpty else { return "tint empty: the default colour" }
        let colours: Set = ["red", "orange", "yellow", "green", "mint", "teal", "cyan", "blue", "indigo", "purple", "pink", "brown", "gray"]
        let known = colours.contains(name) || ModLevel(rawValue: name) != nil
            || (name.count == 7 && name.first == "#" && name.dropFirst().allSatisfy(\.isHexDigit))
        return "tint \(Self.quoted(rendered))" + (known ? "" : " (not a colour: ignored)")
    }

    // MARK: - Controls

    /// Hidden when `when` is false; a section or row also when nothing inside it is shown.
    private func isVisible(_ control: ModControl) -> Bool {
        if let when = control.when, !holds(when) { return false }
        return control.children.isEmpty ? true : control.children.contains(where: isVisible)
    }

    private func markers(of control: ModControl) -> String {
        var markers: [String] = []
        if let when = control.when, !holds(when) {
            markers.append("[hidden]")
        } else if !control.children.isEmpty, !isVisible(control) {
            markers.append("[hidden: nothing inside is shown]")
        }
        if let disabled = control.disabled, holds(disabled) {
            markers.append("[disabled]")
        }
        return markers.map { " " + $0 }.joined()
    }

    /// `head (details) [markers]`, then the lines inside the control.
    private mutating func add(_ control: ModControl, depth: Int) {
        var details: [String] = []
        var head: String
        var inside: [(Int, String)] = []
        func detail(_ text: String?) {
            if let text { details.append(text) }
        }
        func command(_ name: String?) {
            detail(name.map { "runs \($0)" })
        }
        switch control.kind {
        case .section(let section):
            head = "section" + (section.title.map { " " + Self.quoted(render($0)) } ?? "")
            if section.collapsible { detail(section.collapsed ? "collapsible, starts collapsed" : "collapsible") }
        case .row:
            head = "row"
        case .divider:
            head = "divider"
        case .toggle(let toggle):
            let value = state[toggle.bind]
            head = "toggle \(Self.quoted(render(toggle.label))): \(value?.boolValue == true ? "on" : "off")"
            detail(bound(toggle.bind) + (value != nil && value?.boolValue == nil ? ", not true or false: shown as off" : ""))
            command(toggle.command)
        case .slider(let slider):
            let number = state[slider.bind]?.numberValue
            head = "slider \(Self.quoted(render(slider.label))): \(Self.number(number ?? slider.min))\(slider.unit ?? "")"
            detail(bound(slider.bind) + (number == nil ? ", not a number: shows the minimum" : ""))
            detail("\(Self.number(slider.min))…\(Self.number(slider.max))" + (slider.step.map { " step \(Self.number($0))" } ?? ""))
            command(slider.command)
            if slider.live { detail("live") }
        case .stepper(let stepper):
            let number = state[stepper.bind]?.numberValue
            // The number the app starts from when the key holds none (ModInterface.stepperFallback).
            let fallback = min(max(0, stepper.min ?? 0), stepper.max ?? .infinity)
            head = "stepper \(Self.quoted(render(stepper.label))): \(Self.number(number ?? fallback))\(stepper.unit ?? "")"
            detail(bound(stepper.bind) + (number == nil ? ", not a number: shows \(Self.number(fallback))" : ""))
            let range = switch (stepper.min, stepper.max) {
            case let (min?, max?): "\(Self.number(min))…\(Self.number(max)) "
            case let (min?, nil): "from \(Self.number(min)) "
            case let (nil, max?): "up to \(Self.number(max)) "
            case (nil, nil): ""
            }
            detail("\(range)step \(Self.number(stepper.step))")
            command(stepper.command)
        case .picker(let picker):
            let options = picker.optionsFrom.map { ModControl.Picker.Option.options(from: state[$0]) } ?? picker.options
            let selected = options.first { $0.value == state[picker.bind] }
            head = "picker" + (picker.label.map { " " + Self.quoted(render($0)) } ?? "") + ": "
                + (selected.map { Self.quoted($0.label) } ?? "nothing selected")
            detail(bound(picker.bind))
            // A quick picker is always a menu: on a card and in the menus alike.
            detail(isQuick ? "menu" : picker.style?.rawValue ?? (options.count <= 4 ? "segmented" : "menu"))
            if let source = picker.optionsFrom {
                detail("options from \(source)")
                let elements = state[source]?.arrayValue
                if elements == nil {
                    inside.append((1, "no options: \(source) holds no array yet"))
                } else if let elements, elements.count > options.count {
                    inside.append((1, "\(elements.count - options.count) element(s) of \(source) skipped: not options, or beyond 32"))
                }
            }
            command(picker.command)
            for option in options {
                inside.append((1, "option \(option.value.compactJSON): \(Self.quoted(option.label))" + (option == selected ? " [selected]" : "")))
            }
        case .input(let input):
            let value = state[input.bind]
            let text = value.flatMap { $0.isScalar ? $0.text : nil } ?? ""
            head = "input" + (input.label.map { " " + Self.quoted(render($0)) } ?? "") + ": " + Self.quoted(text)
            detail(bound(input.bind) + (value != nil && value?.isScalar == false ? ", not text: shows nothing" : ""))
            detail(input.placeholder.map { "placeholder \(Self.quoted($0))" })
            command(input.command)
        case .button(let button):
            head = "button \(Self.quoted(render(button.label)))"
            command(button.command)
            detail(button.open.map { "opens \($0)" })
            detail(button.copy.map { "copies \(Self.quoted(render($0)))" })
            detail(button.value.map { "value \($0.compactJSON)" })
            if button.style != .normal { detail(button.style.rawValue) }
            detail(button.confirm.map { "asks \(Self.quoted($0))" })
        case .value(let value):
            head = "value \(Self.quoted(render(value.label))): \(Self.quoted(render(value.value)))"
            detail(tint(value.tint))
            if value.copyable { detail("copyable") }
        case .stat(let stat):
            head = "stat \(Self.quoted(render(stat.label))): \(Self.quoted(render(stat.value)))"
            detail(tint(stat.tint))
        case .text(let text):
            head = "text: \(Self.quoted(render(text.text)))"
            if text.style != .body { detail(text.style.rawValue) }
            detail(tint(text.tint))
        case .gauge(let gauge):
            let number = state[gauge.bind]?.numberValue
            let readout = number.map { value in
                // Checked at install, so the format parses.
                gauge.format.flatMap { try? ModValueFormat($0) }.map { $0.string(for: value) } ?? Self.number(value) + (gauge.unit ?? "")
            } ?? "—"
            head = "gauge \(Self.quoted(render(gauge.label))): \(readout)"
            detail(bound(gauge.bind) + (number == nil ? ", not a number: shows the minimum" : ""))
            detail("\(Self.number(gauge.min))…\(Self.number(gauge.max)) \(gauge.style.rawValue)")
            detail(tint(gauge.tint))
        case .chart(let chart):
            head = "chart" + (chart.label.map { " " + Self.quoted(render($0)) } ?? "")
            var shape = "\(chart.style.rawValue), \(chart.points) points"
            if chart.min != nil || chart.max != nil {
                shape += ", " + (chart.min.map(Self.number) ?? "auto") + "…" + (chart.max.map(Self.number) ?? "auto")
            }
            detail(shape)
            detail(chart.unit.map { "unit \(Self.quoted($0))" })
            detail(chart.format.map { "format \(Self.quoted($0))" })
            inside += chart.series.map { (1, series($0)) }
        case .list(let list):
            let value = state[list.bind]
            let items = ModListItem.items(from: value)
            let shown = Array(items.prefix(list.limit ?? .max))
            head = "list: \(shown.count) row\(shown.count == 1 ? "" : "s")"
            detail(value?.arrayValue == nil ? bound(list.bind) + (value == nil ? "" : ", not an array: no rows") : "bind \(list.bind)")
            detail(list.limit.map { "limit \($0)" })
            command(list.command)
            if shown.isEmpty {
                inside.append((1, list.empty.map { "empty: \(Self.quoted($0))" } ?? "empty, no placeholder"))
            }
            for item in shown {
                var row = "row \(Self.quoted(item.title))"
                if let subtitle = item.subtitle { row += ", subtitle \(Self.quoted(subtitle))" }
                if let value = item.value { row += ", value \(Self.quoted(value))" }
                if item.id != item.title { row += ", id \(Self.quoted(item.id))" }
                inside.append((1, row))
            }
            if let array = value?.arrayValue, array.count > items.count {
                inside.append((1, "\(array.count - items.count) element(s) skipped: neither text, a number nor an object with a title"))
            }
        }
        detail(control.help.map { "help \(Self.quoted($0))" })
        add(depth, head + (details.isEmpty ? "" : " (\(details.joined(separator: "; ")))") + markers(of: control))
        for (offset, line) in inside {
            add(depth + offset, line)
        }
        for child in control.children {
            add(child, depth: depth + 1)
        }
        if case .section(let section) = control.kind, let footer = section.footer {
            add(depth + 1, "footer: \(Self.quoted(render(footer)))")
        }
    }

    /// What a chart series plots: an array of numbers as is, or one recorded sample per patch with the key.
    private func series(_ series: ModControl.Chart.Series) -> String {
        let name = "series" + (series.label.map { " " + Self.quoted($0) } ?? "")
        let plotted: String = switch state[series.bind] {
        case nil: "\(series.bind) missing, nothing to plot yet"
        case .number(let value)?: "\(series.bind) = \(Self.number(value)), recorded as one sample per patch that has it"
        case .array(let array)?:
            "\(series.bind) = \(array.compactMap(\.numberValue).count) numbers plotted as they are"
                + (array.contains { $0.numberValue == nil } ? ", other elements skipped" : "")
        case let value?: "\(series.bind) = \(value.compactJSON), not a number or an array of numbers: nothing to plot"
        }
        return "\(name): \(plotted)" + (series.tint.map { " (tint \(Self.quoted($0)))" } ?? "")
    }

    // MARK: - Widgets

    private mutating func add(_ widget: ModWidget) {
        let title = widget.title.map(render).flatMap { $0.isEmpty ? nil : $0 } ?? manifest.name
        var details = ["\(widget.size.rawValue), \(widget.size.columns) column\(widget.size.columns == 1 ? "" : "s")"]
        if let tint = tint(widget.tint) { details.append(tint) }
        let hidden = widget.when.map { holds($0) ? "" : " [hidden]" } ?? ""
        add(1, "widget \(widget.id) \(Self.quoted(title)): \(Self.quoted(render(widget.value))) (\(details.joined(separator: "; ")))\(hidden)")
        if let gauge = widget.gauge {
            let number = state[gauge.bind]?.numberValue
            let fill = number.map { value in
                let fraction = min(max((value - gauge.min) / (gauge.max - gauge.min), 0), 1)
                return "\(Self.number((fraction * 100).rounded()))% full"
            } ?? "not a number: empty"
            add(2, "gauge: \(bound(gauge.bind)), \(Self.number(gauge.min))…\(Self.number(gauge.max)), \(fill)")
        }
        if let chart = widget.chart {
            var shape = "\(chart.style.rawValue), \(chart.points) points"
            if chart.min != nil || chart.max != nil {
                shape += ", " + (chart.min.map(Self.number) ?? "auto") + "…" + (chart.max.map(Self.number) ?? "auto")
            }
            add(2, "chart (\(shape))")
            chart.series.forEach { add(3, series($0)) }
        }
        if widget.detail.isEmpty {
            add(2, "no detail: a click opens the mod's page")
        } else {
            add(2, "detail:")
            widget.detail.forEach { add($0, depth: 3) }
        }
    }
}
