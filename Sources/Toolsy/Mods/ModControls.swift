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

    /// The mod's colour, the default tint of its sliders, gauges and charts.
    var tint: Color { Tint.color(manifest.tint) }
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
                .debugAnchor("\(mod.id)/\(path.map(String.init).joined(separator: "."))")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch control.kind {
        case .section(let section):
            if path.count == 1 {
                SectionGroup(section.title.map(mod.render), footer: section.footer.map(mod.render)) {
                    children(section.children)
                }
            } else {
                NestedSection(mod: mod, section: section, path: path)
            }
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
        case .text(let text):
            StyledText(mod.render(text.text), style: TextStyle(rawValue: text.style.rawValue) ?? .body,
                       tint: Tint.resolve(text.tint.map(mod.render)))
        case .gauge(let gauge): GaugeControl(mod: mod, gauge: gauge)
        case .chart(let chart): ChartControl(mod: mod, chart: chart)
        case .list(let list): ListControl(mod: mod, list: list)
        }
    }

    private func children(_ controls: [ModControl]) -> some View {
        ForEach(controls.indices, id: \.self) { index in
            ModControlView(mod: mod, control: controls[index], path: path + [index])
        }
    }
}

/// A section inside a section: a caption title, its rows and its footer, on the enclosing tile.
private struct NestedSection: View {
    let mod: Mod
    let section: ModControl.Section
    let path: [Int]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title = section.title.map(mod.render), !title.isEmpty {
                Text(title)
                    .font(.tileTitle)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 2)
                    .accessibilityAddTraits(.isHeader)
            }
            Group(subviews: ForEach(section.children.indices, id: \.self) { index in
                ModControlView(mod: mod, control: section.children[index], path: path + [index])
            }) { rows in
                ForEach(rows) { row in
                    if row.id != rows.first?.id { Hairline() }
                    row.padding(.vertical, 7)
                }
            }
            if let footer = section.footer.map(mod.render), !footer.isEmpty {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
    @State private var dragged: Double?

    var body: some View {
        let stored = ModInterface.number(mod.state[slider.bind], fallback: slider.min)
        SliderRow(
            mod.render(slider.label), icon: slider.icon,
            value: Binding(get: { dragged ?? stored }, set: { dragged = $0 }),
            in: slider.min...slider.max, step: slider.step, unit: slider.unit, tint: mod.tint,
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
        PickerRow(
            picker.label.map(mod.render), icon: picker.icon,
            selection: Binding(
                get: { mod.state[picker.bind] ?? .null },
                set: { model.setValue($0, for: picker.bind, command: picker.command, of: mod) }
            ),
            options: picker.options.map { PickerOption(value: $0.value, label: $0.label, icon: $0.icon) },
            presentation: picker.style.flatMap { PickerPresentation(rawValue: $0.rawValue) } ?? .automatic
        )
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

    var body: some View {
        let label = mod.render(button.label)
        GlassButton(label, icon: button.icon, kind: ButtonKind(rawValue: button.style.rawValue) ?? .normal,
                    tint: mod.tint, isBusy: button.command.map(mod.runningCommands.contains) ?? false,
                    fillsWidth: true) {
            press(label: label)
        }
    }

    private func press(label: String) {
        if let open = button.open {
            // Checked at install: an http(s) URL.
            if let url = URL(string: open) { NSWorkspace.shared.open(url) }
            return
        }
        guard let command = button.command else { return }
        let run = { model.run(command, value: button.value, of: mod) }
        guard let question = button.confirm else { return run() }
        panel.confirm(ConfirmationRequest(
            title: question,
            confirmTitle: label,
            isDestructive: button.style == .destructive,
            onConfirm: run
        ))
    }
}

// MARK: - Displays

private struct GaugeControl: View {
    let mod: Mod
    let gauge: ModControl.Gauge

    var body: some View {
        let value = mod.state[gauge.bind]?.numberValue
        let text = value.map { formatNumber($0, unit: gauge.unit) } ?? "—"
        let tint = Tint.resolve(gauge.tint.map(mod.render)) ?? mod.tint
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
    private static let palette: [Color] = [.blue, .orange, .green, .pink, .purple, .teal]

    var body: some View {
        SeriesChart(
            chart.label.map(mod.render),
            series: chart.series.enumerated().map { index, series in
                ChartSeries(series.label, tint: Tint.resolve(series.tint) ?? (index == 0 ? mod.tint : Self.palette[index - 1]),
                            values: mod.history(of: series.bind))
            },
            style: ChartStyle(rawValue: chart.style.rawValue) ?? .line,
            min: chart.min, max: chart.max, unit: chart.unit,
            capacity: ModInterface.chartCapacity(chart, state: mod.state)
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
