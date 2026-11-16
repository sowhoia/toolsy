#if DEBUG
import Foundation
import ToolsyShared

/// Stands in for the privileged helper in debug runs (`--simulate-helper`, implied by `--data-root`):
/// it reports "not installed" until `install()`, approves mods by digest, and runs their "privileged"
/// commands as the current user from a snapshot of the approved files, as the real helper runs them
/// as root. It never shows the administrator prompt. Its state lives in `store` (inside the scratch data
/// root), so it survives a relaunch like the real helper does.
actor SimulatedHelper: PrivilegedExecuting {
    private struct State: Codable {
        var installed = false
        /// As after Toolsy was updated: approvals are kept, but nothing runs until `install()`.
        var needsUpdate = false
        var approvals: [String: String] = [:]
    }

    private let store: URL
    private var state: State {
        didSet { save() }
    }
    /// The next `install()` fails with this, as when the user dismisses the password prompt.
    private var nextInstallError: PrivilegedError?

    init(store: URL) {
        self.store = store
        do {
            state = try JSONDecoder().decode(State.self, from: Data(contentsOf: store.appending(path: "state.json")))
        } catch {
            state = State()
        }
    }

    private var installed: Bool { state.installed && !state.needsUpdate }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
            try JSONEncoder().encode(state).write(to: store.appending(path: "state.json"))
        } catch {
            log("cannot save its state: \(error.localizedDescription)")
        }
    }

    /// Makes the helper look outdated, as after an update of Toolsy.
    func simulateAppUpdate() {
        guard state.installed else { return }
        state.needsUpdate = true
        log("needs an update")
    }

    func failNextInstall(with error: PrivilegedError) {
        nextInstallError = error
    }

    func status() -> HelperStatus {
        !state.installed ? .notInstalled : state.needsUpdate ? .needsUpdate : .ready
    }

    func install() async throws {
        // The real install waits for the password prompt and launchd.
        try await Task.sleep(for: .seconds(2))
        if let error = nextInstallError {
            nextInstallError = nil
            log("install refused: \(error)")
            throw error
        }
        state.installed = true
        state.needsUpdate = false
        log("installed")
    }

    func uninstall() throws {
        state = State()
        try removeIfPresent(store.appending(path: "Mods", directoryHint: .isDirectory))
        log("uninstalled")
    }

    func approvedMods() throws -> [String: String] {
        guard installed else { throw PrivilegedError.helperUnavailable(status()) }
        return state.approvals
    }

    func approve(modID: String, payload: ModPayload) throws {
        guard installed else { throw PrivilegedError.helperUnavailable(status()) }
        let folder = snapshot(of: modID)
        try removeIfPresent(folder)
        for (path, data) in payload.files {
            let file = folder.appending(path: path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: payload.executables.contains(path) ? 0o755 : 0o644],
                                                  ofItemAtPath: file.path(percentEncoded: false))
        }
        state.approvals[modID] = payload.digest
        log("approved \(modID)")
    }

    func revoke(modID: String, keepingData: Bool) throws {
        guard installed else { throw PrivilegedError.helperUnavailable(status()) }
        state.approvals[modID] = nil
        try removeIfPresent(snapshot(of: modID))
        if !keepingData {
            try removeIfPresent(store.appending(path: "Data/\(modID)", directoryHint: .isDirectory))
        }
        log("revoked \(modID)")
    }

    func run(modID: String, command name: String, input: CommandInput) async throws -> CommandResult {
        guard installed else { throw PrivilegedError.helperUnavailable(status()) }
        guard state.approvals[modID] != nil else { throw PrivilegedError.notApproved(modID: modID) }
        let folder = snapshot(of: modID)
        let manifest = try ModManifest.load(from: Data(contentsOf: folder.appending(path: ModManifest.fileName)))
        guard let command = manifest.commands[name], command.privileged else {
            throw PrivilegedError.rejected("\(name) is not a privileged command of \(modID)")
        }
        let data = store.appending(path: "Data/\(modID)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        let invocation = command.invocation(modDirectory: folder)
        log("run \(modID) \(name)")
        return try await ProcessRunner.run(ProcessRunner.Request(
            executable: invocation.executable,
            arguments: invocation.arguments,
            environment: CommandEnvironment.variables(modID: modID, modDirectory: folder, dataDirectory: data,
                                                      input: input, privileged: false),
            currentDirectory: folder,
            stdin: command.stdin ? try JSONEncoder().encode(input) : nil,
            timeout: command.timeout
        ))
    }

    private func snapshot(of modID: String) -> URL {
        store.appending(path: "Mods/\(modID)", directoryHint: .isDirectory)
    }

    private func removeIfPresent(_ url: URL) throws {
        do {
            try FileManager.default.removeItem(at: url)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return
        }
    }

    private nonisolated func log(_ message: String) {
        FileHandle.standardOutput.write(Data("SimulatedHelper: \(message)\n".utf8))
    }
}
#endif
