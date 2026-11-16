import Foundation
import ToolsyShared

/// One run of a mod's command, or one moment in the life of its service: what a mod's author needs to
/// see why something did not happen. It never holds state values or standard output, which can carry
/// user data; only the end of standard error, where programs explain their failures.
public struct CommandRun: Identifiable, Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        case succeeded
        /// Exited with this non-zero status, or 128 + the signal number when killed by a signal.
        case failed(exitCode: Int32)
        case timedOut
        /// The program could not be started, or the helper did not run it; the message says why.
        case couldNotStart(String)
        /// A privileged command refused because the mod lacks administrator access.
        case refused
        /// The service was started: when the mod is switched on or Toolsy starts with it on.
        case started
        /// The service was started again by Toolsy: after a crash, or because a setting or (in developer
        /// mode) one of the mod's files changed.
        case restarted
        /// The service ended by itself with this status; stopping it on purpose is not recorded.
        case exited(status: Int32)
    }

    /// Counts up within the mod, so it identifies the run in `Mod.recentRuns`.
    public let id: Int
    public let command: String
    public let event: ModEvent
    public let started: Date
    /// How long the command ran; for an exited service, how long it had been running.
    public let duration: Duration
    public let outcome: Outcome
    /// The last 2 000 characters of standard error.
    public let standardError: String
    /// Standard output was a JSON object and was applied as a patch.
    public let outputWasPatch: Bool

    /// How many runs `Mod.recentRuns` keeps.
    static let kept = 20
    static let errorCharacters = 2_000

    init(id: Int, command: String, event: ModEvent, started: Date, duration: Duration, outcome: Outcome,
         standardError: Data = Data(), outputWasPatch: Bool = false) {
        self.id = id
        self.command = command
        self.event = event
        self.started = started
        self.duration = duration
        self.outcome = outcome
        self.standardError = String(String(decoding: standardError, as: UTF8.self).suffix(Self.errorCharacters))
        self.outputWasPatch = outputWasPatch
    }
}
