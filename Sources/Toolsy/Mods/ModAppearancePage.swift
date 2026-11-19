import SwiftUI
import ToolsyEngine

/// Where the user gives a mod a name, a colour and an icon of their own. Each choice applies at once wherever Toolsy
/// shows the mod, and each falls back to the mod's own.
struct ModAppearancePage: View {
    let id: String
    @Environment(ModsModel.self) private var model

    var body: some View {
        if let mod = model.mod(id: id) {
            AppearanceEditor(mod: mod)
        } else {
            PageScaffold(String(localized: "Appearance")) {
                Tile {
                    EmptyState(String(localized: "This mod is no longer installed"), symbol: "puzzlepiece.extension")
                }
            }
        }
    }
}

private struct AppearanceEditor: View {
    let mod: Mod
    @Environment(ModsModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let look = model.preferences.look(of: mod.id)
        let appearance = model.appearance(of: mod)
        let own = ModAppearance(manifest: mod.manifest)
        // The header is the preview: it changes with every choice.
        PageScaffold(String(localized: "Appearance"), subtitle: appearance.name,
                     badge: PageBadge(symbol: appearance.symbol, tint: appearance.tint)) {
            SectionGroup(footer: String(localized: "Leave it empty for the mod’s own name, “\(own.name)”.")) {
                TextFieldRow(String(localized: "Name"), placeholder: own.name, value: look.name ?? "") { name in
                    change { $0.name = name }
                }
                .debugAnchor("look-name")
            }
            SectionGroup(String(localized: "Colour")) {
                ColourChoices(selection: look.tint, own: own.tint) { name in change { $0.tint = name } }
                    .padding(.vertical, 2)
            }
            SectionGroup(String(localized: "Icon")) {
                SymbolChoices(selection: look.icon, own: own.symbol, tint: appearance.tint) { symbol in change { $0.icon = symbol } }
                    .padding(.vertical, 2)
            }
            GlassButton(String(localized: "Use the Mod’s Own Look"), icon: "arrow.uturn.backward", fillsWidth: true) {
                change { $0 = ModLook() }
            }
            .disabled(look.isEmpty)
            .debugAnchor("look-reset")
        }
    }

    private func change(_ body: (inout ModLook) -> Void) {
        var look = model.preferences.look(of: mod.id)
        body(&look)
        withAnimation(Motion.resolve(Motion.snappy, reduceMotion: reduceMotion)) {
            model.preferences.setLook(look, of: mod.id, originalName: mod.manifest.name)
        }
    }
}

/// Seven to a row: the mod's own colour first, then the palette.
private struct ColourChoices: View {
    let selection: String?
    let own: Color
    let onSelect: (String?) -> Void

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 8) {
            ColourSwatch(colour: own, isSelected: selection == nil, label: String(localized: "The mod’s own colour"), isOwn: true) {
                onSelect(nil)
            }
            .debugAnchor("look-tint:own")
            ForEach(ModLook.palette, id: \.self) { name in
                ColourSwatch(colour: Tint.color(name), isSelected: selection == name, label: Self.label(of: name)) {
                    onSelect(name)
                }
                .debugAnchor("look-tint:\(name)")
            }
        }
    }

    private static func label(of name: String) -> String {
        switch name {
        case "red": String(localized: "Red")
        case "orange": String(localized: "Orange")
        case "yellow": String(localized: "Yellow")
        case "green": String(localized: "Green")
        case "mint": String(localized: "Mint")
        case "teal": String(localized: "Teal")
        case "cyan": String(localized: "Cyan")
        case "blue": String(localized: "Blue")
        case "indigo": String(localized: "Indigo")
        case "purple": String(localized: "Purple")
        case "pink": String(localized: "Pink")
        case "brown": String(localized: "Brown")
        default: String(localized: "Grey")
        }
    }
}

/// A round drop of colour; the chosen one is ringed in its colour. The mod's own carries a mark that says so.
private struct ColourSwatch: View {
    let colour: Color
    let isSelected: Bool
    let label: String
    var isOwn = false
    let action: () -> Void
    @State private var isHovered = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(colour)
                Circle().fill(LinearGradient(colors: [.white.opacity(0.24), .white.opacity(0)], startPoint: .top, endPoint: .center))
                GlassRim(shape: Circle(), intensity: 0.7, lineWidth: 0.75)
                if isOwn {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(colour.prefersDarkLabel(in: colorScheme) ? .black : .white)
                }
            }
            .frame(width: 26, height: 26)
            .padding(4)
            .overlay {
                Circle()
                    .strokeBorder(colour, lineWidth: 2)
                    .opacity(isSelected ? 1 : 0)
                    .scaleEffect(isSelected ? 1 : 0.8)
            }
            .scaleEffect(isHovered && !isSelected ? 1.06 : 1)
            .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .animation(Motion.snappy, value: isSelected)
        .animation(Motion.fade, value: isHovered)
        .onHover { isHovered = $0 }
    }
}

/// Seven to a row: the mod's own icon first, then the icons offered for mods.
private struct SymbolChoices: View {
    let selection: String?
    let own: String
    let tint: Color
    let onSelect: (String?) -> Void

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 6) {
            // A chosen icon that is the mod's own (an update of the mod can make it so) is shown as the mod's own.
            SymbolCell(symbol: own, isSelected: selection == nil || selection == own, tint: tint,
                       label: String(localized: "The mod’s own icon")) {
                onSelect(nil)
            }
            .debugAnchor("look-icon:own")
            ForEach(ModLook.symbols.filter { $0 != own }, id: \.self) { symbol in
                SymbolCell(symbol: symbol, isSelected: selection == symbol, tint: tint) { onSelect(symbol) }
                    .debugAnchor("look-icon:\(symbol)")
            }
        }
    }
}

/// An icon on a well of glass; the chosen one is a badge in the mod's colour. Without a `label` VoiceOver reads the
/// symbol's own description.
private struct SymbolCell: View {
    let symbol: String
    let isSelected: Bool
    let tint: Color
    var label: String?
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        Button(action: action) {
            SymbolImage(symbol, renderingMode: .monochrome)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary.opacity(isHovered ? 0.9 : 0.7)))
                .frame(width: 36, height: 36)
                .background {
                    if isSelected {
                        shape.fill(tint)
                        shape.fill(LinearGradient(colors: [.white.opacity(0.24), .white.opacity(0)], startPoint: .top, endPoint: .center))
                        GlassRim(shape: shape, intensity: 0.7, lineWidth: 0.75)
                    } else {
                        shape.fill(Color.primary.opacity(isHovered ? 0.1 : 0.05))
                    }
                }
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .modifier(OptionalLabel(label: label))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .animation(Motion.snappy, value: isSelected)
        .animation(Motion.fade, value: isHovered)
        .onHover { isHovered = $0 }
    }
}

private struct OptionalLabel: ViewModifier {
    let label: String?

    func body(content: Content) -> some View {
        if let label {
            content.help(label).accessibilityLabel(label)
        } else {
            content
        }
    }
}
