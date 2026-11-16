import AppKit

enum SingleInstance {
    static let openPanelNotification = Notification.Name("app.toolsy.open-panel")

    /// Returns `true` if another instance of the app is running; that instance has then been
    /// asked to open its panel and this one should exit.
    static func handOffToRunningInstance() -> Bool {
        // Outside a bundle (a bare `swift run`) there is no identity to compare; just run.
        guard let identifier = Bundle.main.bundleIdentifier else { return false }
        let ownProcess = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .filter { $0.processIdentifier != ownProcess && !$0.isTerminated }
        guard !others.isEmpty else { return false }
        DistributedNotificationCenter.default().postNotificationName(
            openPanelNotification, object: nil, userInfo: nil, deliverImmediately: true
        )
        return true
    }

    /// Calls `handler` whenever a later launch asks this instance to open its panel.
    static func observeHandOffs(_ handler: @escaping @MainActor @Sendable () -> Void) -> NSObjectProtocol {
        DistributedNotificationCenter.default().addObserver(
            forName: openPanelNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated(handler)
        }
    }
}
