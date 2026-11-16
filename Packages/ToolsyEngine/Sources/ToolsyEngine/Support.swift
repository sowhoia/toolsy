import Foundation
import os
import ToolsyShared

/// A failure of the engine itself, with a message meant for the user or the mod author.
public struct EngineError: LocalizedError, Equatable, Sendable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}

/// Command failures and service restarts. Never log state values: they can hold user data.
let logger = Logger(subsystem: ToolsyPaths.bundleIdentifier, category: "mods")

/// The last line of `data` that is not blank, trimmed; what a failing program usually says about why.
func lastNonEmptyLine(_ data: Data) -> String? {
    String(decoding: data, as: UTF8.self)
        .split(whereSeparator: \.isNewline)
        .lazy
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .last { !$0.isEmpty }
}

/// SIGTERM to the process group led by `leader`, then SIGKILL to whatever is left of it after `grace`.
/// Foundation starts every child as the leader of its own group, so this reaches all it started.
func terminateProcessGroup(ledBy leader: Int32, grace: Duration) async {
    // Never 0 or 1: as a negated target those mean "my own group" and "every process I may signal".
    guard leader > 1, kill(-leader, SIGTERM) == 0 else { return }
    let deadline = ContinuousClock.now + grace
    while kill(-leader, 0) == 0, ContinuousClock.now < deadline {
        do {
            try await Task.sleep(for: .milliseconds(10))
        } catch {
            break
        }
    }
    if kill(-leader, 0) == 0 {
        kill(-leader, SIGKILL)
    }
}

/// Delays the engine waits on. Tests compress them with `scale`; the app uses the specified values.
struct EngineTiming: Sendable {
    var scale: Double = 1
    /// The clock rate limits are measured with; tests substitute one they advance by hand.
    var now: @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }

    func duration(_ seconds: Double) -> Duration {
        .seconds(seconds * scale)
    }

    /// Between SIGTERM and SIGKILL when a service is stopped.
    var killGrace: Duration { duration(2) }
    /// A service that ran this long before crashing restarts after the shortest delay again.
    var healthyRun: Duration { duration(30) }
    /// Settings changes arrive in bursts (a dragged slider); the service restarts once they settle.
    var settingsDebounce: Duration { duration(0.3) }
    /// How long a change to a mod's approval waits for a privileged command of the mod to finish.
    var busyPatience: Duration { duration(5) }
    /// A mod notifies at most once per this interval; later notifications within it are dropped.
    var notificationInterval: Duration { duration(5) }
    /// The same notification again within this window is dropped.
    var repeatedNotificationWindow: Duration { duration(60) }
    /// Developer mode: changes in the mods folder are acted on once they have settled this long.
    var folderSettle: Duration { duration(0.3) }
    /// Developer mode: changes are acted on this long after the first of them at the latest, so a mod
    /// that keeps writing into its folder does not hold up the changes of the others.
    var folderPatience: Duration { duration(1.5) }
    /// Developer mode: a service restarts for changed files at most once per this interval, so a mod
    /// that writes into its own folder cannot restart itself as fast as it writes.
    var fileRestartInterval: Duration { duration(1) }
}
