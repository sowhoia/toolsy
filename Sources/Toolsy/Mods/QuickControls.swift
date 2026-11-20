import SwiftUI
import ToolsyEngine
import ToolsyShared

/// A mod's quick controls on its card (MOD_FORMAT.md, "Quick controls"): buttons, toggles and pickers side by side in
/// equal columns, in the mod's colour.
struct ModQuickRow: View {
    let mod: Mod
    let controls: [(index: Int, control: ModControl)]

    var body: some View {
        EqualColumns(spacing: 6) {
            ForEach(controls, id: \.index) { item in
                ModQuickControl(mod: mod, control: item.control)
                    .debugAnchor("quick:\(mod.id)/\(item.index)")
            }
        }
    }
}

/// One quick control. On a card a toggle is a chip whose check fills in the mod's colour while it is on, so it never
/// reads as a prominent button beside it; `inRow`, at the end of a compact row, it is a switch, and a button with an
/// icon is a round one that leaves the row to the mod's name.
struct ModQuickControl: View {
    let mod: Mod
    let control: ModControl
    var inRow = false
    @Environment(ModsModel.self) private var model
    @Environment(\.modTint) private var tint
    @State private var copied = CopyFeedback()

    var body: some View {
        content
            .disabled(control.disabled.map(mod.evaluate) ?? false)
            .modifier(ControlHelp(text: control.help))
    }

    @ViewBuilder
    private var content: some View {
        switch control.kind {
        case .button(let button):
            let label = mod.render(button.label)
            Group {
                if inRow, let icon = button.icon {
                    IconButton(copied.isShowing ? "checkmark" : icon, label: label) {
                        model.press(button, of: mod) { copied.copy($0) }
                    }
                } else {
                    GlassButton(copied.isShowing ? String(localized: "Copied") : label, icon: copied.isShowing ? "checkmark" : button.icon,
                                kind: ButtonKind(rawValue: button.style.rawValue) ?? .normal, tint: tint,
                                isBusy: button.command.map(mod.runningCommands.contains) ?? false, fillsWidth: !inRow) {
                        model.press(button, of: mod) { copied.copy($0) }
                    }
                }
            }
            // Nothing to copy yet: copying would only empty the pasteboard.
            .disabled(button.copy.map { mod.render($0).isEmpty } ?? false)
            .animation(Motion.snappy, value: copied.isShowing)
        case .toggle(let toggle):
            let label = mod.render(toggle.label)
            let isOn = ModInterface.isOn(mod.state[toggle.bind])
            if inRow {
                GlassSwitch(isOn: Binding(get: { isOn }, set: { set(toggle, $0) }), tint: tint, label: label)
            } else {
                ToggleChip(label: label, isOn: isOn, tint: tint) { set(toggle, !isOn) }
            }
        case .picker(let picker):
            let options = ModInterface.options(of: picker, state: mod.state)
            let label = picker.label.map(mod.render) ?? ""
            MenuPicker(
                selection: Binding(get: { mod.state[picker.bind] ?? .null },
                                   set: { model.setValue($0, for: picker.bind, command: picker.command, of: mod) }),
                options: options.map { PickerOption(value: $0.value, label: $0.label, icon: $0.icon) },
                label: label,
                fillsWidth: !inRow
            )
            // The capsule shows the choice; what is chosen is said by its tooltip.
            .help(control.help ?? label)
            .disabled(options.isEmpty)
        default:
            EmptyView()
        }
    }

    private func set(_ toggle: ModControl.Toggle, _ isOn: Bool) {
        model.setValue(.bool(isOn), for: toggle.bind, command: toggle.command, of: mod)
    }
}

/// A toggle among a card's quick controls: a capsule of glass with a check that fills in the mod's colour, over a wash
/// of it, while the toggle is on. Its text shrinks or ends in "…" before the check goes.
private struct ToggleChip: View {
    let label: String
    let isOn: Bool
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isOn ? tint : Color.secondary)
                    .contentTransition(.symbolEffect(.replace))
                Text(label)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .font(.system(size: 13))
            .frame(maxWidth: .infinity)
            .frame(height: Metrics.controlHeight)
            .padding(.horizontal, 10)
        }
        .buttonStyle(ChipStyle(wash: isOn ? tint : nil))
        .animation(Motion.snappy, value: isOn)
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? String(localized: "On") : String(localized: "Off"))
        .accessibilityAddTraits(.isToggle)
    }
}

/// The glass of a chip: lit under the pointer, swelling a little when pressed, with a wash of colour while it holds
/// something on.
private struct ChipStyle: ButtonStyle {
    let wash: Color?
    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.primary)
            .background {
                GlassChip(shape: Capsule(), isHovered: isHovered && isEnabled, isPressed: configuration.isPressed)
                if let wash { Capsule().fill(wash.opacity(0.16)) }
            }
            .contentShape(.capsule)
            .contentShape(.focusEffect, .capsule)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 1.04 : 1)
            .opacity(isEnabled ? 1 : 0.45)
            .animation(Motion.liquid, value: configuration.isPressed)
            .animation(Motion.fade, value: isHovered)
            .onHover { isHovered = $0 }
    }
}

/// A mod's quick controls as the items of a context menu: a button is an item, a toggle an item ticked while on, a
/// picker a submenu of its options.
struct ModQuickMenuItems: View {
    let mod: Mod
    @Environment(ModsModel.self) private var model

    var body: some View {
        ForEach(model.shownQuickControls(of: mod), id: \.index) { item in
            QuickMenuItem(mod: mod, control: item.control)
                .disabled(item.control.disabled.map(mod.evaluate) ?? false)
        }
    }
}

private struct QuickMenuItem: View {
    let mod: Mod
    let control: ModControl
    @Environment(ModsModel.self) private var model

    var body: some View {
        switch control.kind {
        case .button(let button):
            let label = mod.render(button.label)
            Group {
                if let icon = button.icon {
                    Button(label, systemImage: icon) { press(button) }
                } else {
                    Button(label) { press(button) }
                }
            }
            .disabled(button.copy.map { mod.render($0).isEmpty } ?? false)
        case .toggle(let toggle):
            Toggle(mod.render(toggle.label), isOn: Binding(
                get: { ModInterface.isOn(mod.state[toggle.bind]) },
                set: { model.setValue(.bool($0), for: toggle.bind, command: toggle.command, of: mod) }
            ))
        case .picker(let picker):
            let options = ModInterface.options(of: picker, state: mod.state)
            Picker(picker.label.map(mod.render) ?? "", selection: Binding(
                get: { mod.state[picker.bind] ?? .null },
                set: { model.setValue($0, for: picker.bind, command: picker.command, of: mod) }
            )) {
                ForEach(options.indices, id: \.self) { index in
                    Text(options[index].label).tag(options[index].value)
                }
            }
            .disabled(options.isEmpty)
        default:
            EmptyView()
        }
    }

    private func press(_ button: ModControl.Button) {
        // A menu has no room to say "Copied"; VoiceOver hears it all the same.
        model.press(button, of: mod) { CopyFeedback().copy($0) }
    }
}
