import SwiftUI

/// The page the panel opens on: the dashboard and the list of mods.
struct RootPage: View {
    @Environment(PanelState.self) private var panel

    var body: some View {
        PageScaffold("Toolsy") {
            DashboardView()
            ModsSection()
        } accessory: {
            IconButton("gearshape", label: String(localized: "Settings")) { panel.push(.settings) }
                .debugAnchor("settings")
        }
    }
}
