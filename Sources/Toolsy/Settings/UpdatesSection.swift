import SwiftUI

/// Looking for a new version of Toolsy, in Settings.
struct UpdatesSection: View {
    @Environment(UpdateChecker.self) private var updates

    var body: some View {
        SectionGroup(
            String(localized: "Updates"),
            footer: String(localized: "Toolsy asks GitHub for its latest release and sends nothing but its own version. Nothing is downloaded or installed by itself.")
        ) {
            SwitchRow(String(localized: "Check for Updates Automatically"), icon: "arrow.triangle.2.circlepath", isOn: Binding(
                get: { updates.checksAutomatically },
                set: { updates.checksAutomatically = $0 }
            ))
            .debugAnchor("updates-automatic")
            switch updates.status {
            case .available(let release):
                ControlLabel(String(localized: "Toolsy \(release.version.description) is available"), icon: "arrow.down.circle.fill",
                             tint: .accentColor)
            case .upToDate:
                ControlLabel(String(localized: "Toolsy is up to date"), icon: "checkmark.circle.fill", tint: StatusLevel.ok.color)
            case .failed(let message):
                InlineBanner(message, kind: .warning)
            case .idle, .checking:
                EmptyView()
            }
            HStack(spacing: 8) {
                if case .available(let release) = updates.status {
                    // Opens the release's page in the browser; nothing is downloaded here.
                    GlassButton(String(localized: "Download Update"), kind: .prominent, fillsWidth: true) { updates.openPage(of: release) }
                        .debugAnchor("update-download")
                }
                GlassButton(String(localized: "Check Now"), isBusy: updates.status == .checking, fillsWidth: true) {
                    Task { await updates.checkNow() }
                }
                .debugAnchor("update-check")
            }
        }
        .onDisappear { updates.dismissResult() }
    }
}
