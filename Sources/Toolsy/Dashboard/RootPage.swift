import SwiftUI

/// The page the panel opens on: an update when there is one, the dashboard and the list of mods, or, in Customise,
/// the dashboard with its editing tools and the arrangement of the mods.
struct RootPage: View {
    @Environment(PanelState.self) private var panel
    @Environment(DashboardStore.self) private var dashboard
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        PageScaffold("Toolsy") {
            if !dashboard.isEditing {
                UpdateBanner()
            }
            DashboardView()
                .zIndex(1)  // a dragged tile floats above the editing tools
            if dashboard.isEditing {
                Group {
                    WidgetGallery()
                    DashboardSettings()
                    ModsArrangement()
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
                IconButton("square.grid.2x2", label: String(localized: "Customise")) { setEditing(true) }
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
