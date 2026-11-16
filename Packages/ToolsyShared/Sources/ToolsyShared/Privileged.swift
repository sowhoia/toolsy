import Foundation

public enum HelperStatus: Sendable, Equatable {
    /// The privileged helper has never been installed, or was removed.
    case notInstalled
    /// A helper is installed but is older than the bundled one or does not accept this build of the app.
    /// Installing again (one administrator prompt) fixes both.
    case needsUpdate
    case ready
}

public enum PrivilegedError: LocalizedError, Equatable, Sendable {
    /// The helper is missing or outdated; `install()` is needed first.
    case helperUnavailable(HelperStatus)
    /// The user dismissed the administrator prompt.
    case cancelled
    /// The mod, in its current form, has not been approved to run as root.
    case notApproved(modID: String)
    /// A privileged command is still running, and what was asked cannot be done until it has finished.
    case busy
    /// The helper refused the request.
    case rejected(String)
    /// Talking to the helper failed.
    case connection(String)

    public var errorDescription: String? {
        switch self {
        case .helperUnavailable(.needsUpdate): "The administrator helper needs to be updated."
        case .helperUnavailable: "The administrator helper is not installed."
        case .cancelled: "Administrator access was not granted."
        case .notApproved(let modID): "The mod \"\(modID)\" is not approved to run with administrator privileges."
        case .busy: "A command is still running with administrator privileges. Try again when it has finished."
        case .rejected(let reason): reason
        case .connection(let reason): "Could not reach the administrator helper: \(reason)"
        }
    }
}

/// Runs mod commands as root without asking for a password each time.
///
/// The real implementation talks to the privileged helper over XPC. The helper executes commands
/// only from the snapshot taken by `approve`, never from the user-writable mod directory.
///
/// A command that has started is never interrupted: `uninstall`, and `approve` and `revoke` of the mod
/// it belongs to, throw `PrivilegedError.busy` until it has finished.
public protocol PrivilegedExecuting: Sendable {
    func status() async -> HelperStatus

    /// Installs or updates the helper. This is the one step that shows the system administrator prompt.
    func install() async throws

    /// Removes the helper together with every approved snapshot.
    func uninstall() async throws

    /// Approved mod ids, each with the payload digest it was approved with.
    func approvedMods() async throws -> [String: String]

    /// Snapshots `payload` into the helper's root-owned store, replacing an earlier approval of the same mod.
    func approve(modID: String, payload: ModPayload) async throws

    /// Deletes the mod's approved snapshot and, unless `keepingData`, the root-owned data folder of its
    /// privileged commands. Not an error when there is nothing to delete.
    func revoke(modID: String, keepingData: Bool) async throws

    /// Runs a command the approved manifest marks as privileged, feeding it `input`.
    func run(modID: String, command: String, input: CommandInput) async throws -> CommandResult
}
