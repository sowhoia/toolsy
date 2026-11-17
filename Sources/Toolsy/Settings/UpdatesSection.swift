import SwiftUI

/// Looking for a new version of Toolsy and installing it, in Settings.
struct UpdatesSection: View {
    @Environment(UpdateChecker.self) private var updates
    @Environment(UpdateInstaller.self) private var installer

    var body: some View {
        SectionGroup(
            String(localized: "Updates"),
            footer: String(localized: "Toolsy asks GitHub for its latest release and sends nothing but its own version. An update is downloaded only when you click Update and Restart, and installed only if Toolsy’s developer signed it.")
        ) {
            SwitchRow(String(localized: "Check for Updates Automatically"), icon: "arrow.triangle.2.circlepath", isOn: Binding(
                get: { updates.checksAutomatically },
                set: { updates.checksAutomatically = $0 }
            ))
            .debugAnchor("updates-automatic")
            if let installation = installer.installation {
                VStack(alignment: .leading, spacing: 8) {
                    ControlLabel(UpdateBanner.title(of: installation), icon: "arrow.down.circle.fill", tint: .accentColor)
                    InstallationStatus(installation: installation)
                }
            } else {
                switch updates.status {
                case .available(let release):
                    VStack(alignment: .leading, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            ControlLabel(String(localized: "Toolsy \(release.version.description) is available"), icon: "arrow.down.circle.fill",
                                         tint: .accentColor)
                            Text(UpdateOffer.summary(of: release, running: updates.running))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.leading, 26)
                        }
                        UpdateOffer(release: release)
                    }
                case .upToDate:
                    ControlLabel(String(localized: "Toolsy is up to date"), icon: "checkmark.circle.fill", tint: StatusLevel.ok.color)
                case .failed(let message):
                    InlineBanner(message, kind: .warning)
                case .idle, .checking:
                    EmptyView()
                }
            }
            // While a new version is on offer or being installed, its own buttons are what matters.
            if installer.installation == nil, !updates.status.isAvailable {
                GlassButton(String(localized: "Check Now"), isBusy: updates.status == .checking, fillsWidth: true) {
                    Task { await updates.checkNow() }
                }
                .debugAnchor("update-check")
            }
        }
        .onDisappear { updates.dismissResult() }
    }
}

private extension UpdateChecker.Status {
    var isAvailable: Bool {
        if case .available = self { true } else { false }
    }
}
