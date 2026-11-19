import AppKit
import SwiftUI
import ToolsyEngine
import ToolsyShared

/// A mod's `ui`, rendered as MOD_FORMAT.md "Interface" specifies: top-level sections become tiles,
/// other top-level controls are grouped into untitled tiles.
struct ModControls: View {
    let mod: Mod
    private let blocks: [ModInterface.Block]

    init(mod: Mod) {
        self.mod = mod
        blocks = ModInterface.blocks(of: mod.manifest.ui)
    }

    var body: some View {
        let ui = mod.manifest.ui
        ForEach(blocks) { block in
            switch block {
            case .section(let index):
                ModControlView(mod: mod, control: ui[index], path: [index])
            case .group(let indices):
                ControlGroupTile(mod: mod, indices: indices)
            }
        }
    }
}

/// Top-level controls between sections, shown as one untitled group while any of them is visible.
private struct ControlGroupTile: View {
    let mod: Mod
    let indices: [Int]

    var body: some View {
        let ui = mod.manifest.ui
        if indices.contains(where: { mod.isVisible(ui[$0]) }) {
            SectionGroup {
                ForEach(indices, id: \.self) { index in
                    ModControlView(mod: mod, control: ui[index], path: [index])
                }
            }
        }
    }
}

extension Mod {
    /// Whether `control` is shown: its `when` holds, and a row or section has something visible inside.
    func isVisible(_ control: ModControl) -> Bool {
        if let when = control.when, !evaluate(when) { return false }
        switch control.kind {
        case .row(let row): return row.children.contains(where: isVisible)
        case .section(let section): return section.children.contains(where: isVisible)
        default: return true
        }
    }
}

/// One control of a mod and, for sections and rows, everything inside it. `path` is its index path
/// in `ui`, which names it for the debug script.
struct ModControlView: View {
    let mod: Mod
    let control: ModControl
    let path: [Int]
    var inRow = false

    var body: some View {
        if mod.isVisible(control) {
            content
                .disabled(control.disabled.map(mod.evaluate) ?? false)
                .modifier(ControlHelp(text: control.help))
                .debugAnchor("\(mod.id)/\(path.map(String.init).joined(separator: "."))")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch control.kind {
        case .section(let section):
            SectionControl(mod: mod, section: section, path: path)
        case .row(let row):
            EqualColumns(spacing: 8) {
                ForEach(row.children.indices, id: \.self) { index in
                    ModControlView(mod: mod, control: row.children[index], path: path + [index], inRow: true)
                }
            }
        case .divider:
            if !inRow { SectionBreak() }
        case .toggle(let toggle): ToggleControl(mod: mod, toggle: toggle)
        case .slider(let slider): SliderControl(mod: mod, slider: slider)
        case .stepper(let stepper): StepperControl(mod: mod, stepper: stepper)
        case .picker(let picker): PickerControl(mod: mod, picker: picker)
        case .input(let input): InputControl(mod: mod, input: input)
        case .button(let button): ButtonControl(mod: mod, button: button)
        case .value(let value):
            ValueRow(mod.render(value.label), value: mod.render(value.value), icon: value.icon,
                     tint: Tint.resolve(value.tint.map(mod.render)), copyable: value.copyable)
        case .stat(let stat):
            StatView(mod.render(stat.label), value: mod.render(stat.value), icon: stat.icon,
                     tint: Tint.resolve(stat.tint.map(mod.render)))
        case .text(let text):
            StyledText(mod.render(text.text), style: TextStyle(rawValue: text.style.rawValue) ?? .body,
                       tint: Tint.resolve(text.tint.map(mod.render)))
        case .gauge(let gauge): GaugeControl(mod: mod, gauge: gauge)
        case .chart(let chart): ChartControl(mod: mod, chart: chart)
        case .list(let list): ListControl(mod: mod, list: list)
        }
    }
}

/// A control's `help`: its tooltip, and the hint VoiceOver reads after its label.
private struct ControlHelp: ViewModifier {
    let text: String?

    func body(content: Content) -> some View {
        if let text, !text.isEmpty {
            content
                .help(text)
                .accessibilityHint(text)
        } else {
            content
        }
    }
}

/// A section: a tile of its own at the top level, a captioned group of rows inside another section. A
/// collapsible one folds by its title; folded, its controls are not rendered, so they cost nothing.
private struct SectionControl: View {
    let mod: Mod
    let section: ModControl.Section
    let path: [Int]
    @Environment(ModsModel.self) private var model
    @Environment(\.modControlPlace) private var place

    var body: some View {
        let title = section.title.map(mod.render)
        let footer = section.footer.map(mod.render)
        if path.count == 1 {
            SectionGroup(title, footer: footer, isExpanded: isExpanded) { rows }
        } else {
            NestedSection(title: title, footer: footer, isExpanded: isExpanded) { rows }
        }
    }

    private var isExpanded: Binding<Bool>? {
        guard section.collapsible else { return nil }
        let folds = model.sectionFolds
        let key = SectionFolds.Key(modID: mod.id, place: place, path: path)
        return Binding(get: { !folds.isFolded(key, section: section) }, set: { folds.setFolded(!$0, key) })
    }

    private var rows: some View {
        ForEach(section.children.indices, id: \.self) { index in
            ModControlView(mod: mod, control: section.children[index], path: path + [index])
        }
    }
}

/// A section inside a section: a caption title, its rows and its footer, on the enclosing tile.
private struct NestedSection<Content: View>: View {
    let title: String?
    let footer: String?
    let isExpanded: Binding<Bool>?
    @ViewBuilder let content: Content

    var body: some View {
        let title = title.flatMap { $0.isEmpty ? nil : $0 }
        // As in `SectionGroup`: only a title can fold the section.
        let expanded = title == nil || isExpanded?.wrappedValue != false
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                Group {
                    if let isExpanded {
                        FoldableTitle(title, isExpanded: isExpanded)
                    } else {
                        Text(title)
                            .font(.tileTitle)
                            .foregroundStyle(.secondary)
                            .accessibilityAddTraits(.isHeader)
                    }
                }
                .padding(.bottom, expanded ? 2 : 0)
            }
            if expanded {
                VStack(alignment: .leading, spacing: 0) {
                    Group(subviews: content) { rows in
                        ForEach(rows) { row in
                            if row.id != rows.first?.id { Hairline() }
                            row.padding(.vertical, 7)
                        }
                    }
                    if let footer, !footer.isEmpty {
                        Text(footer)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .transition(.opacity)
            }
        }
    }
}

// MARK: - Inputs

private struct ToggleControl: View {
    let mod: Mod
    let toggle: ModControl.Toggle
    @Environment(ModsModel.self) private var model

    var body: some View {
        SwitchRow(mod.render(toggle.label), icon: toggle.icon, isOn: Binding(
            get: { ModInterface.isOn(mod.state[toggle.bind]) },
            set: { model.setValue(.bool($0), for: toggle.bind, command: toggle.command, of: mod) }
        ))
    }
}

/// While dragging, the slider shows its own value; the state (and the command) follow on release, or
/// with every step for a `live` slider.
private struct SliderControl: View {
    let mod: Mod
    let slider: ModControl.Slider
    @Environment(ModsModel.self) private var model
    @Environment(\.modTint) private var tint
    @State private var dragged: Double?

    var body: some View {
        let stored = ModInterface.number(mod.state[slider.bind], fallback: slider.min)
        SliderRow(
            mod.render(slider.label), icon: slider.icon,
            value: Binding(get: { dragged ?? stored }, set: { dragged = $0 }),
            in: slider.min...slider.max, step: slider.step, unit: slider.unit, tint: tint,
            onChange: slider.live ? { store($0) } : nil,
            onCommit: { value in
                dragged = nil
                // A live slider has already stored every value it passed.
                if !slider.live, value != stored { store(value) }
            }
        )
    }

    private func store(_ value: Double) {
        model.setValue(.number(value), for: slider.bind, command: slider.command, of: mod)
    }
}

private struct StepperControl: View {
    let mod: Mod
    let stepper: ModControl.Stepper
    @Environment(ModsModel.self) private var model

    var body: some View {
        StepperRow(
            mod.render(stepper.label), icon: stepper.icon,
            value: Binding(
                get: { ModInterface.number(mod.state[stepper.bind], fallback: ModInterface.stepperFallback(stepper)) },
                set: { model.setValue(.number($0), for: stepper.bind, command: stepper.command, of: mod) }
            ),
            in: ModInterface.stepperRange(stepper), step: stepper.step, unit: stepper.unit
        )
    }
}

private struct PickerControl: View {
    let mod: Mod
    let picker: ModControl.Picker
    @Environment(ModsModel.self) private var model

    var body: some View {
        // With `optionsFrom` the list can change under the selection: a value no longer offered simply
        // shows nothing selected until the user or a command picks one.
        let options = ModInterface.options(of: picker, state: mod.state)
        PickerRow(
            picker.label.map(mod.render), icon: picker.icon,
            selection: Binding(
                get: { mod.state[picker.bind] ?? .null },
                set: { model.setValue($0, for: picker.bind, command: picker.command, of: mod) }
            ),
            options: options.map { PickerOption(value: $0.value, label: $0.label, icon: $0.icon) },
            presentation: picker.style.flatMap { PickerPresentation(rawValue: $0.rawValue) } ?? .automatic
        )
        .disabled(options.isEmpty)
    }
}

private struct InputControl: View {
    let mod: Mod
    let input: ModControl.Input
    @Environment(ModsModel.self) private var model

    var body: some View {
        // The field keeps what the user is typing until it is committed; state arriving meanwhile
        // shows only once the field is no longer being edited.
        TextFieldRow(input.label.map(mod.render), icon: input.icon, placeholder: input.placeholder ?? "",
                     value: ModInterface.text(mod.state[input.bind])) { text in
            model.setValue(.string(text), for: input.bind, command: input.command, of: mod)
        }
    }
}

private struct ButtonControl: View {
    let mod: Mod
    let button: ModControl.Button
    @Environment(ModsModel.self) private var model
    @Environment(PanelState.self) private var panel
    @Environment(\.modTint) private var tint
    @State private var copied = CopyFeedback()

    var body: some View {
        let label = mod.render(button.label)
        let kind = ButtonKind(rawValue: button.style.rawValue) ?? .normal
        if let copy = button.copy {
            let text = mod.render(copy)
            // Confirms in place, like a copyable value row.
            GlassButton(copied.isShowing ? String(localized: "Copied") : label, icon: copied.isShowing ? "checkmark" : button.icon,
                        kind: kind, tint: tint, fillsWidth: true) {
                perform({ copied.copy(text) }, label: label)
            }
            // Nothing to copy yet: copying would only empty the pasteboard.
            .disabled(text.isEmpty)
            .animation(Motion.snappy, value: copied.isShowing)
        } else {
            GlassButton(label, icon: button.icon, kind: kind, tint: tint,
                        isBusy: button.command.map(mod.runningCommands.contains) ?? false, fillsWidth: true) {
                press(label: label)
            }
        }
    }

    private func press(label: String) {
        if let open = button.open {
            // Checked at install: an http(s) URL.
            guard let url = URL(string: open) else { return }
            perform({ NSWorkspace.shared.open(url) }, label: label)
        } else if let command = button.command {
            perform({ model.run(command, value: button.value, of: mod) }, label: label)
        }
    }

    /// What the button does, after its `confirm` question when it has one, whichever of the three it does.
    private func perform(_ action: @escaping () -> Void, label: String) {
        guard let question = button.confirm else { return action() }
        panel.confirm(ConfirmationRequest(
            title: question,
            confirmTitle: label,
            isDestructive: button.style == .destructive,
            onConfirm: action
        ))
    }
}

// MARK: - Displays

private struct GaugeControl: View {
    let mod: Mod
    let gauge: ModControl.Gauge
    @Environment(\.modTint) private var modTint

    var body: some View {
        let value = mod.state[gauge.bind]?.numberValue
        let format = ModInterface.valueFormat(gauge.format)
        let text = value.map { format?.string(for: $0) ?? formatNumber($0, unit: gauge.unit) } ?? "—"
        let tint = Tint.resolve(gauge.tint.map(mod.render)) ?? modTint
        let label = mod.render(gauge.label)
        switch gauge.style {
        case .bar:
            BarGauge(label, icon: gauge.icon, value: value ?? gauge.min, in: gauge.min...gauge.max, text: text,
                     tint: tint, updatesOften: true)
        case .ring:
            RingGauge(value: value ?? gauge.min, in: gauge.min...gauge.max, text: text, tint: tint, size: 56,
                      label: label, updatesOften: true)
                .frame(maxWidth: .infinity)
        }
    }
}

private struct ChartControl: View {
    let mod: Mod
    let chart: ModControl.Chart
    @Environment(\.modTint) private var tint
    private static let palette: [Color] = [.blue, .orange, .green, .pink, .purple, .teal]

    var body: some View {
        SeriesChart(
            chart.label.map(mod.render),
            series: chart.series.enumerated().map { index, series in
                ChartSeries(series.label, tint: Tint.resolve(series.tint) ?? (index == 0 ? tint : Self.palette[index - 1]),
                            values: mod.history(of: series.bind))
            },
            style: ChartStyle(rawValue: chart.style.rawValue) ?? .line,
            min: chart.min, max: chart.max, unit: chart.unit,
            capacity: ModInterface.chartCapacity(chart, state: mod.state),
            format: ModInterface.valueFormat(chart.format).map { format in format.string(for:) }
        )
    }
}

/// The rows of a `list`, separated like the rows of the group around it.
private struct ListControl: View {
    let mod: Mod
    let list: ModControl.List
    @Environment(ModsModel.self) private var model

    var body: some View {
        let items = Array(ModListItem.items(from: mod.state[list.bind]).prefix(list.limit ?? .max))
        if items.isEmpty {
            if let empty = list.empty, !empty.isEmpty {
                Text(empty)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: Metrics.rowMinHeight)
                    .multilineTextAlignment(.center)
            }
        } else {
            // One view with its own separators, so it lays out the same whatever wraps it.
            VStack(spacing: 0) {
                ForEach(items.indices, id: \.self) { index in
                    let item = items[index]
                    if index > 0 { Hairline() }
                    ListRow(item.title, subtitle: item.subtitle, value: item.value, icon: item.icon, tint: Tint.resolve(item.tint),
                            action: list.command.map { command in
                                { model.run(command, key: list.bind, value: .string(item.id), of: mod) }
                            })
                        .padding(.top, index == 0 ? 0 : 7)
                        .padding(.bottom, index == items.count - 1 ? 0 : 7)
                }
            }
        }
    }
}
