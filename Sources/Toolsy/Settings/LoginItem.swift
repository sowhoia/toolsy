import Foundation
import os
import ServiceManagement
import ToolsyShared

/// Whether Toolsy starts at login, as `SMAppService.mainApp` reports it.
@Observable
final class LoginItem {
    enum State: Equatable {
        case on
        case off
        /// Registered, but the user has to allow it in System Settings → General → Login Items.
        case needsApproval
        /// macOS does not know this copy of the app (`SMAppService.Status.notFound`), e.g. a build run
        /// from where it was built rather than installed.
        case unavailable
    }

    private(set) var state: State = .off
    private(set) var lastError: String?
    /// False in scripted debug runs, which must never add a login item.
    let canChange: Bool

    @ObservationIgnored private let service = SMAppService.mainApp
    private static let registeredOnceKey = "LoginItemRegisteredOnce"
    private static let logger = Logger(subsystem: ToolsyPaths.bundleIdentifier, category: "login-item")

    init(canChange: Bool) {
        self.canChange = canChange
        refresh()
    }

    func refresh() {
        state = switch service.status {
        case .enabled: .on
        case .requiresApproval: .needsApproval
        case .notFound: .unavailable
        case .notRegistered: .off
        @unknown default: .off
        }
    }

    /// The owner wants Toolsy always running, so the first launch registers it; after that the
    /// user's choice stands, including turning it off.
    func registerOnFirstLaunch() {
        let defaults = UserDefaults.standard
        guard canChange, !defaults.bool(forKey: Self.registeredOnceKey) else { return }
        // A bare executable (`swift run`) has no bundle macOS could start.
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        do {
            try service.register()
        } catch {
            Self.logger.error("registering as a login item failed: \(error.localizedDescription, privacy: .public)")
        }
        refresh()
        // Waiting for the user's approval counts as done: registering again would not change that.
        if state == .on || state == .needsApproval {
            defaults.set(true, forKey: Self.registeredOnceKey)
        }
    }

    func set(_ on: Bool) {
        guard canChange else { return }
        do {
            if on { try service.register() } else { try service.unregister() }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
