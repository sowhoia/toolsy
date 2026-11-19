import SwiftUI
import ToolsyEngine

/// The mods in the panel's Customise mode: the style of the list, and every mod, hidden ones too, to drag into order
/// and to hide from the list or show in it again.
struct ModsArrangement: View {
    private static let scrollID = "mods-arrangement"

    /// Starts Customise and, once it has opened, scrolls the root page to the mods: Arrange Mods in a mod's context menu.
    static func show(dashboard: DashboardStore, panel: PanelState, reduceMotion: Bool) {
        withAnimation(Motion.resolve(Motion.gentle, reduceMotion: reduceMotion), completionCriteria: .logicallyComplete) {
            dashboard.isEditing = true
        } completion: {
            panel.scrollTarget = scrollID
        }
    }

    @Environment(ModsModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let styles = [
        PickerOption(value: ModListStyle.cards, label: String(localized: "Cards"), icon: "rectangle.grid.1x2"),
        PickerOption(value: ModListStyle.compact, label: String(localized: "Compact"), icon: "list.bullet"),
    ]

    var body: some View {
        let mods = model.arrangedMods
        let preferences = model.preferences
        if !mods.isEmpty {
            SectionGroup(String(localized: "Mods"),
                         footer: String(localized: "Drag a mod to move it. A hidden mod keeps working, and its widgets stay on the dashboard.")) {
                PickerRow(String(localized: "List Style"), selection: Binding(
                    get: { preferences.listStyle },
                    set: { style in withAnimation(Motion.resolve(Motion.gentle, reduceMotion: reduceMotion)) { preferences.listStyle = style } }
                ), options: Self.styles)
                .debugAnchor("mods-style")
                ReorderableRows(mods, rowHeight: 40) { id, position in
                    preferences.move(id, toPosition: position, among: mods.map(\.id))
                } row: { mod in
                    ArrangedMod(mod: mod)
                }
            }
            .id(Self.scrollID)
            .debugAnchor("mods-arrangement")
        }
    }
}

/// A mod in the arrangement: what it looks like, whether it is listed, and the handle that says it can be dragged.
private struct ArrangedMod: View {
    let mod: Mod
    @Environment(ModsModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let appearance = model.appearance(of: mod)
        let isHidden = model.preferences.isHidden(mod.id)
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                IconBadge(appearance.symbol, tint: appearance.tint, size: 24)
                Text(appearance.name)
                    .font(.rowLabel)
                    .lineLimit(1)
            }
            // A hidden mod is greyed, as hidden files are in Finder.
            .opacity(isHidden ? 0.45 : 1)
            .accessibilityElement(children: .combine)
            .accessibilityValue(isHidden ? String(localized: "Hidden") : "")
            Spacer(minLength: 8)
            Button {
                withAnimation(Motion.resolve(Motion.snappy, reduceMotion: reduceMotion)) { model.preferences.setHidden(!isHidden, mod.id) }
            } label: {
                Image(systemName: isHidden ? "eye.slash" : "eye")
                    .font(.system(size: 13))
                    .foregroundStyle(isHidden ? .tertiary : .secondary)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(GlyphButtonStyle())
            .help(isHidden ? String(localized: "Show in the List") : String(localized: "Hide from the List"))
            .accessibilityLabel(isHidden ? String(localized: "Show “\(appearance.name)” in the List")
                                         : String(localized: "Hide “\(appearance.name)” from the List"))
            .debugAnchor("arrange-hide:\(mod.id)")
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .contentShape(.rect)
        .debugAnchor("arrange:\(mod.id)")
    }
}

/// A small round button around a symbol, lit up under the pointer.
private struct GlyphButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                Circle().fill(Color.primary.opacity(configuration.isPressed ? 0.14 : isHovered ? 0.07 : 0))
            }
            .contentShape(.circle)
            .contentShape(.focusEffect, .circle)
            .animation(Motion.fade, value: isHovered)
            .onHover { isHovered = $0 }
    }
}
