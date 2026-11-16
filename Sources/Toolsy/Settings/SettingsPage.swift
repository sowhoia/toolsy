import AppKit
import os
import SwiftUI
import ToolsyShared

/// Settings: starting at login, the administrator helper, developer mode, the mods folder, the version
/// and quitting.
struct SettingsPage: View {
    @Environment(PanelState.self) private var panel
    @Environment(ModsModel.self) private var model
    @Environment(LoginItem.self) private var loginItem

    var body: some View {
        PageScaffold(String(localized: "Settings")) {
            loginSection
            helperSection
            SectionGroup(footer: String(localized: "Mods reload when their files change, and each mod’s page shows its recent runs.")) {
                SwitchRow(String(localized: "Developer Mode"), icon: "hammer", isOn: Binding(
                    get: { model.developerMode },
                    set: { model.developerMode = $0 }
                ))
                .debugAnchor("developer-mode")
            }
            SectionGroup {
                ListRow(String(localized: "Show Mods Folder in Finder"), icon: "folder.fill", tint: .blue) { showModsFolder() }
                ValueRow(String(localized: "Version"), value: Self.version, icon: "info.circle", copyable: true)
                #if DEBUG
                ListRow(String(localized: "Component gallery"), icon: "square.grid.2x2.fill", tint: .indigo) {
                    panel.push(.gallery)
                }
                #endif
            }
            GlassButton(String(localized: "Quit Toolsy"), icon: "power", fillsWidth: true) {
                NSApp.terminate(nil)
            }
        }
        .onAppear { loginItem.refresh() }
        // The helper can change behind Toolsy's back; show what is true now.
        .task { await model.store.refreshAccess() }
    }

    private var loginSection: some View {
        SectionGroup(footer: loginItem.canChange ? nil : String(localized: "Not changed in this test run.")) {
            SwitchRow(String(localized: "Open at Login"), icon: "person.crop.circle.badge.checkmark", isOn: Binding(
                get: { loginItem.state == .on || loginItem.state == .needsApproval },
                set: { loginItem.set($0) }
            ))
            .disabled(!loginItem.canChange || loginItem.state == .unavailable)
            switch loginItem.state {
            case .needsApproval:
                HStack(spacing: 10) {
                    Text("Allow Toolsy in System Settings to open it at login.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    GlassButton(String(localized: "Open…"), action: { loginItem.openSystemSettings() })
                }
            case .unavailable:
                Text("macOS doesn’t recognise this copy of Toolsy. Open Toolsy from the Applications folder to use this.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .on, .off:
                EmptyView()
            }
            if let error = loginItem.lastError {
                InlineBanner(error, kind: .error)
            }
        }
    }

    private var helperSection: some View {
        let status = model.store.helperStatus
        return SectionGroup(
            String(localized: "Administrator helper"),
            footer: String(localized: "Mods that change system settings run their commands through Toolsy’s helper. Toolsy installs it with the first mod that needs it; macOS asks for your password only then, and once more after Toolsy is updated.")
        ) {
            ValueRow(String(localized: "Status"), value: Self.text(for: status), icon: "lock.shield",
                     tint: status == .ready ? StatusLevel.ok.color : status == .needsUpdate ? StatusLevel.warn.color : nil)
            if status == .needsUpdate {
                Text("Toolsy was updated. The helper has to be updated once before mods can use it again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Nothing to press while there is no helper: installing a mod that needs it installs it.
            if status != .notInstalled {
                HStack(spacing: 8) {
                    if status == .needsUpdate {
                        GlassButton(String(localized: "Update…"), kind: .prominent, isBusy: model.isChangingHelper,
                                    fillsWidth: true, action: { model.installHelper() })
                            .debugAnchor("helper-install")
                    }
                    GlassButton(String(localized: "Remove…"), kind: .destructive, isBusy: model.isChangingHelper,
                                fillsWidth: true, action: { model.uninstallHelper() })
                        .debugAnchor("helper-remove")
                }
            }
        }
    }

    private static func text(for status: HelperStatus) -> String {
        switch status {
        case .notInstalled: String(localized: "Not installed")
        case .needsUpdate: String(localized: "Needs an update")
        case .ready: String(localized: "Ready")
        }
    }

    private func showModsFolder() {
        let folder = model.directories.mods
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            Logger(subsystem: ToolsyPaths.bundleIdentifier, category: "settings")
                .error("cannot create the mods folder: \(error.localizedDescription, privacy: .public)")
        }
        NSWorkspace.shared.open(folder)
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "\(short) (\($0))" } ?? short
    }
}
