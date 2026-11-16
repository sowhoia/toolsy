import SwiftUI

/// The page the panel opens on: the dashboard and the list of mods, or, while the dashboard is being
/// edited, the dashboard and its editing tools.
struct RootPage: View {
    @Environment(PanelState.self) private var panel
    @Environment(DashboardStore.self) private var dashboard
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        PageScaffold("Toolsy") {
            DashboardView()
                .zIndex(1)  // a dragged tile floats above the editing tools
            if dashboard.isEditing {
                Group {
                    WidgetGallery()
                    DashboardSettings()
                }
                .transition(.opacity)
            } else {
                ModsSection()
                    .transition(.opacity)
            }
        } accessory: {
            if dashboard.isEditing {
                GlassButton(String(localized: "Done"), kind: .prominent) { setEditing(false) }
                    .keyboardShortcut(.defaultAction)
                    .debugAnchor("edit-done")
            } else {
                IconButton("square.grid.2x2", label: String(localized: "Edit Widgets")) { setEditing(true) }
                    .debugAnchor("edit-widgets")
                IconButton("gearshape", label: String(localized: "Settings")) { panel.push(.settings) }
                    .debugAnchor("settings")
            }
        }
    }

    private func setEditing(_ editing: Bool) {
        withAnimation(Motion.resolve(Motion.gentle, reduceMotion: reduceMotion)) { dashboard.isEditing = editing }
    }
}
