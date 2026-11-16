import Foundation
import ToolsyShared

/// A notification a mod asked for with `notify` in a patch. `ModStore.notificationHandler` receives it.
public struct ModNotification: Sendable, Equatable {
    public let modID: String
    public let modName: String
    /// The mod's name when the patch gave no title. At most 80 characters.
    public let title: String
    /// Never blank. At most 240 characters.
    public let body: String

    static let maxTitleLength = 80
    static let maxBodyLength = 240

    /// Reads the `notify` value of a patch: text is the body, an object gives `title` and `body`.
    /// Nil when there is nothing to show (a blank or missing body) or the value has another shape.
    init?(_ value: JSONValue, modID: String, modName: String) {
        let title: String?
        let body: String?
        switch value {
        case .string(let text):
            (title, body) = (nil, text)
        case .object(let object):
            (title, body) = (object["title"]?.stringValue, object["body"]?.stringValue)
        default:
            return nil
        }
        guard let body = body.map({ Self.clip($0, to: Self.maxBodyLength) }), !body.isEmpty else { return nil }
        let clippedTitle = title.map { Self.clip($0, to: Self.maxTitleLength) } ?? ""
        self.modID = modID
        self.modName = modName
        self.title = clippedTitle.isEmpty ? Self.clip(modName, to: Self.maxTitleLength) : clippedTitle
        self.body = body
    }

    /// Trimmed, and cut to `length` characters ending in "…" when longer.
    private static func clip(_ text: String, to length: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > length ? String(trimmed.prefix(length - 1)) + "…" : trimmed
    }
}

/// Keeps a mod from flooding the user: at most one notification per mod every `notificationInterval`,
/// and the same notification not again within `repeatedNotificationWindow`. Excess ones are dropped.
struct NotificationThrottle {
    enum Verdict: Equatable {
        case deliver, tooSoon, repeated
    }

    /// Delivered notifications per mod id still inside the repeat window, oldest first.
    private var delivered: [String: [(notification: ModNotification, at: ContinuousClock.Instant)]] = [:]

    mutating func admit(_ notification: ModNotification, timing: EngineTiming) -> Verdict {
        let now = timing.now()
        var recent = delivered[notification.modID, default: []].filter { $0.at.duration(to: now) < timing.repeatedNotificationWindow }
        defer { delivered[notification.modID] = recent.isEmpty ? nil : recent }
        if let last = recent.last, last.at.duration(to: now) < timing.notificationInterval {
            return .tooSoon
        }
        if recent.contains(where: { $0.notification == notification }) {
            return .repeated
        }
        recent.append((notification, now))
        return .deliver
    }
}
