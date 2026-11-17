import Foundation
import os
import ToolsyEngine
import ToolsyShared
import UserNotifications

private let logger = Logger(subsystem: ToolsyPaths.bundleIdentifier, category: "notifications")

/// The part of `UNUserNotificationCenter` mod notifications use, so tests and debug runs can stand in for it.
protocol UserNotificationCenter: AnyObject {
    func authorizationStatus() async -> UNAuthorizationStatus
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
    func add(_ request: UNNotificationRequest) async throws
}

extension UNUserNotificationCenter: UserNotificationCenter {
    func authorizationStatus() async -> UNAuthorizationStatus {
        await notificationSettings().authorizationStatus
    }
}

/// Shows the notifications mods ask for (`notify` in a patch, already rate-limited by the store) as system
/// notifications, one group per mod, and opens the panel on the mod's page when the user clicks one. Toolsy's own
/// notifications (`Topic`) go the same way, each kind a group of its own.
/// Permission is asked the first time a notification arrives; while it is refused, notifications are dropped.
final class ModNotifier: NSObject {
    /// Toolsy's own kinds of notification. Each is a group, as a mod is, named so that no mod's id can take it: ids
    /// have no colon.
    enum Topic: String {
        /// Alerts about the Mac; a click opens the dashboard.
        case alerts = "toolsy:alerts"

        var page: PanelPage {
            switch self {
            case .alerts: .root
            }
        }
    }

    let center: any UserNotificationCenter
    /// Shows the panel on a page (nil: the page it would open on); set by the app delegate.
    var openPanel: (PanelPage?) -> Void = { _ in }
    private let mods: ModsModel
    /// The permission prompt on screen, which every notification arriving meanwhile waits for.
    private var authorization: Task<Bool, Never>?
    private var reportedRefusal = false

    init(center: any UserNotificationCenter, mods: ModsModel) {
        self.center = center
        self.mods = mods
        super.init()
        if let system = center as? UNUserNotificationCenter {
            // Set at launch, before a click on a notification of an earlier run can be delivered.
            system.delegate = self
        }
        mods.store.notificationHandler = { [weak self] notification in
            Task { await self?.show(notification) }
        }
    }

    /// The system's notification centre, unless there must be none: a debug run on scratch data must not post to
    /// the owner's Notification Centre, and `UNUserNotificationCenter.current()` traps in a process without a
    /// bundle identifier (a bare executable).
    static func center(for options: LaunchOptions) -> any UserNotificationCenter {
        #if DEBUG
        if options.dataRoot != nil || options.simulateHelper { return LoggedNotifications() }
        #endif
        return Bundle.main.bundleIdentifier == nil ? LoggedNotifications() : UNUserNotificationCenter.current()
    }

    func show(_ notification: ModNotification) async {
        guard await isAllowed() else { return }
        do {
            try await center.add(Self.request(for: notification))
        } catch {
            logger.error("mod \(notification.modID, privacy: .public): the notification was not shown: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Shows one of Toolsy's own notifications. It replaces the one with the same `id` if that is still shown, so
    /// an alert that comes back is listed once.
    func show(title: String, body: String, topic: Topic, id: String) async {
        guard await isAllowed() else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.threadIdentifier = topic.rawValue
        do {
            try await center.add(UNNotificationRequest(identifier: "\(topic.rawValue):\(id)", content: content, trigger: nil))
        } catch {
            logger.error("\(topic.rawValue, privacy: .public): the notification was not shown: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Whether the user turned Toolsy's notifications off. With `askingFirst`, a user who never answered is asked
    /// now; without, that counts as not refused.
    func isRefused(askingFirst: Bool) async -> Bool {
        if askingFirst { return !(await isAllowed()) }
        return await center.authorizationStatus() == .denied
    }

    /// Whether notifications may be shown now, asking the user if they never answered.
    private func isAllowed() async -> Bool {
        let allowed: Bool
        switch await center.authorizationStatus() {
        case .authorized, .provisional:
            allowed = true
        case .notDetermined:
            let request = authorization ?? Task {
                defer { authorization = nil }
                do {
                    return try await center.requestAuthorization(options: [.alert])
                } catch {
                    logger.error("asking for permission to notify failed: \(error.localizedDescription, privacy: .public)")
                    return false
                }
            }
            authorization = request
            allowed = await request.value
        default:  // denied
            allowed = false
        }
        if allowed {
            reportedRefusal = false
        } else if !reportedRefusal {
            reportedRefusal = true
            logger.notice("notifications are dropped: Toolsy may not show notifications")
        }
        return allowed
    }

    static func request(for notification: ModNotification) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        // Groups a mod's notifications, and names the mod a click opens.
        content.threadIdentifier = notification.modID
        return UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
    }

    /// A click on a notification of the group `thread`: Toolsy's own open their page, a mod's its page.
    func open(thread: String) async {
        if let topic = Topic(rawValue: thread) {
            openPanel(topic.page)
        } else {
            await open(modID: thread)
        }
    }

    /// A click on a notification of `modID`: its page if the mod is still installed, else the panel as it opens.
    func open(modID: String) async {
        // A click can launch Toolsy; the mods are loading then.
        await mods.waitUntilStarted()
        openPanel(mods.mod(id: modID) != nil ? .mod(modID) : nil)
    }
}

extension ModNotifier: UNUserNotificationCenterDelegate {
    /// Toolsy has no windows a notification would compete with: show it while the panel is open too.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
        await open(thread: response.notification.request.content.threadIdentifier)
    }
}

/// Stands in for Notification Centre where there must be none: logs what would be shown. In a debug build it also
/// prints a `SCRIPT NOTIFY` line and keeps the requests, so a debug script can check them.
final class LoggedNotifications: UserNotificationCenter {
    #if DEBUG
    private(set) var shown: [UNNotificationRequest] = []
    #endif

    func authorizationStatus() async -> UNAuthorizationStatus { .authorized }

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool { true }

    func add(_ request: UNNotificationRequest) async throws {
        let content = request.content
        logger.notice("\(content.threadIdentifier, privacy: .public) notified: \(content.title, privacy: .public): \(content.body, privacy: .public)")
        #if DEBUG
        shown.append(request)
        FileHandle.standardOutput.write(Data("SCRIPT NOTIFY \(content.threadIdentifier) “\(content.title)” “\(content.body)”\n".utf8))
        #endif
    }
}
