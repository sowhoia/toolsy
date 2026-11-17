import Foundation
import os
import Synchronization
import ToolsyHelperXPC
import ToolsyShared

/// The helper's operations. Every argument is validated as hostile even though the peer passed the
/// code requirement: a bug in the app must not turn into a way to run arbitrary code as root.
final class HelperService: Sendable {
    /// Far more than any command input needs, small enough that a request cannot exhaust memory.
    static let maxInputBytes = 4 * 1024 * 1024

    let store: ModStore
    /// Deleted on uninstall besides the store: the launchd plist and the helper binary.
    let installedFiles: [URL]
    let memoryTools: MemoryTools
    private let locks = ModLocks()
    /// True while `reclaimMemory` runs; a second request is refused rather than queued.
    private let isReclaimingMemory = Mutex(false)
    private let logger = Logger(subsystem: HelperConstants.label, category: "operations")

    init(store: ModStore, installedFiles: [URL], memoryTools: MemoryTools = .production) {
        self.store = store
        self.installedFiles = installedFiles
        self.memoryTools = memoryTools
    }

    func approvedMods() throws -> [String: String] {
        try store.approvedDigests()
    }

    func approve(modID: String, files: [String: Data], executables: [String]) async throws {
        let payload = try Self.validatedPayload(modID: modID, files: files, executables: executables)
        try await unlessBusy(modID) {
            try store.store(payload, as: modID)
        }
        logger.notice("approved \(modID, privacy: .public) (\(payload.files.count) files, digest \(payload.digest, privacy: .public))")
    }

    func revoke(modID: String, keepingData: Bool) async throws {
        try Self.requireValidID(modID)
        try await unlessBusy(modID) {
            try store.remove(modID, keepingData: keepingData)
        }
        logger.notice("revoked \(modID, privacy: .public)\(keepingData ? ", data kept" : "", privacy: .public)")
    }

    func run(modID: String, command name: String, input inputData: Data) async throws -> CommandResult {
        try Self.requireValidID(modID)
        guard Self.isValidCommandName(name) else {
            throw HelperError.failed("invalid command name")
        }
        let input = try Self.validatedInput(inputData, command: name)
        return try await exclusively(modID) {
            guard store.hasSnapshot(modID) else { throw HelperError.notApproved }
            let snapshot = store.snapshotDirectory(modID)
            // The command definition comes from the approved copy, never from the request.
            let manifest: ModManifest
            do {
                manifest = try ModManifest.load(from: Data(contentsOf: snapshot.appending(path: ModManifest.fileName)))
            } catch {
                throw HelperError.failed("the approved snapshot of \(modID) cannot be loaded: \(error.localizedDescription)")
            }
            guard manifest.id == modID else {
                throw HelperError.failed("the approved snapshot of \(modID) declares another id")
            }
            guard let command = manifest.commands[name] else {
                throw HelperError.failed("\(modID) has no command \(name)")
            }
            guard command.privileged else {
                throw HelperError.failed("\(modID)/\(name) is not a privileged command")
            }
            let dataDirectory = try store.prepareDataDirectory(modID)
            let environment = CommandEnvironment.variables(
                modID: modID, modDirectory: snapshot, dataDirectory: dataDirectory, input: input, privileged: true
            )
            // Foundation cuts C strings at NUL; refuse rather than hand root a silently altered value.
            guard !environment.contains(where: { $0.key.utf8.contains(0) || $0.value.utf8.contains(0) }) else {
                throw HelperError.failed("the command input contains NUL characters")
            }
            let invocation = command.invocation(modDirectory: snapshot)
            let request = ProcessRunner.Request(
                executable: invocation.executable,
                arguments: invocation.arguments,
                environment: environment,
                currentDirectory: snapshot,
                // Re-encoded from the validated value, so the program receives exactly what was checked.
                stdin: command.stdin ? try JSONEncoder().encode(input) : nil,
                timeout: command.timeout
            )
            let result: CommandResult
            do {
                result = try await ProcessRunner.run(request)
            } catch let error as ProcessRunnerError {
                throw HelperError.failed(error.message)
            }
            logger.notice("ran \(modID, privacy: .public)/\(name, privacy: .public): exit \(result.exitCode)\(result.timedOut ? ", timed out" : "", privacy: .public)")
            return result
        }
    }

    /// Runs the fixed steps of `memoryTools` one after the other; a step that fails does not stop the next.
    func reclaimMemory() async throws -> MemoryReclaimReport {
        let started = isReclaimingMemory.withLock { running in
            defer { running = true }
            return !running
        }
        guard started else { throw HelperError.reclaimingMemory }
        defer { isReclaimingMemory.withLock { $0 = false } }

        let tools = memoryTools
        let flushed = await runTool(tools.purge, [], timeout: tools.purgeTimeout)
        let warned = await runTool(tools.memoryPressure, MemoryTools.warnArguments, timeout: tools.pressureTimeout)
        if !warned {
            // `memory_pressure -S` puts the level back to normal only after its sleep and installs no
            // signal handler, so one that was killed by the timeout or failed after setting the level
            // leaves the system at "warn". Setting "normal" the same way it does ends every path there.
            // Its exit status 0 means it reset the level itself, so a successful run needs no extra step.
            if !(await runTool(tools.memoryPressure, MemoryTools.normalArguments, timeout: tools.restoreTimeout)) {
                logger.fault("the memory-pressure level could not be set back to normal")
            }
        }
        let report = MemoryReclaimReport(diskCacheFlushed: flushed, pressureWarningSent: warned)
        logger.notice("reclaimed memory: disk cache \(flushed ? "flushed" : "not flushed", privacy: .public), pressure warning \(warned ? "sent" : "not sent", privacy: .public)")
        return report
    }

    /// Runs one tool with a fixed environment and no input; true when it exited with status 0 in time.
    private func runTool(_ tool: URL, _ arguments: [String], timeout: TimeInterval) async -> Bool {
        let name = tool.lastPathComponent
        let result: CommandResult
        do {
            result = try await ProcessRunner.run(ProcessRunner.Request(
                executable: tool, arguments: arguments, environment: MemoryTools.environment,
                currentDirectory: URL(filePath: "/", directoryHint: .isDirectory), timeout: timeout,
                // Kept only for the log of a failure.
                outputLimit: 4096
            ))
        } catch {
            logger.error("cannot run \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
        guard result.succeeded else {
            let stderr = String(decoding: result.stderr, as: UTF8.self)
            logger.error("\(name, privacy: .public) \(arguments, privacy: .public) failed: exit \(result.exitCode)\(result.timedOut ? ", timed out" : "", privacy: .public): \(stderr, privacy: .public)")
            return false
        }
        return true
    }

    /// Deletes the whole store, the plist and the binary. The caller has drained every other operation.
    func uninstall() throws {
        for url in [store.root] + installedFiles {
            try FileChecks.removeIfPresent(url)
        }
        logger.notice("uninstalled")
    }

    func logRefusal(_ operation: String, _ error: any Error) {
        logger.error("\(operation, privacy: .public) refused: \(error.localizedDescription, privacy: .private)")
    }

    // MARK: Validation

    static func requireValidID(_ modID: String) throws {
        guard ModManifest.isValidID(modID) else {
            throw HelperError.failed("invalid mod id")
        }
    }

    /// Same rule as `ModManifest`'s command names, which ToolsyShared does not export.
    static func isValidCommandName(_ name: String) -> Bool {
        name.wholeMatch(of: /[A-Za-z_][A-Za-z0-9_-]{0,63}/) != nil
    }

    /// Everything `approve` requires before anything touches the store.
    static func validatedPayload(modID: String, files: [String: Data], executables: [String]) throws -> ModPayload {
        try requireValidID(modID)
        let payload: ModPayload
        do {
            payload = try ModPayload(files: files, executables: Set(executables))
        } catch {
            throw HelperError.failed(error.localizedDescription)
        }
        let manifest: ModManifest
        do {
            manifest = try ModManifest.load(from: payload.manifestData)
        } catch {
            throw HelperError.failed("\(ModManifest.fileName): \(error.localizedDescription)")
        }
        guard manifest.id == modID else {
            throw HelperError.failed("\(ModManifest.fileName) declares the id \(manifest.id), not \(modID)")
        }
        let privileged = manifest.commands.filter(\.value.privileged).sorted { $0.key < $1.key }
        guard !privileged.isEmpty else {
            throw HelperError.failed("\(modID) declares no privileged command")
        }
        for (name, command) in privileged {
            guard case .exec(let file) = command.program else { continue }
            guard payload.files[file] != nil else {
                throw HelperError.failed("commands.\(name): \(file) is not part of the mod")
            }
            guard payload.executables.contains(file) else {
                throw HelperError.failed("commands.\(name): \(file) is not executable")
            }
        }
        return payload
    }

    static func validatedInput(_ data: Data, command name: String) throws -> CommandInput {
        guard data.count <= maxInputBytes else {
            throw HelperError.failed("the command input is larger than \(maxInputBytes / 1024 / 1024) MB")
        }
        let input: CommandInput
        do {
            input = try JSONValue.decode(CommandInput.self, from: data)
        } catch {
            throw HelperError.failed("the command input is not valid")
        }
        guard input.command == name else {
            throw HelperError.failed("the command input names another command")
        }
        // Keys become TOOLSY_STATE_<key> variable names.
        guard input.key.map(ModManifest.isValidKey) ?? true, input.state.keys.allSatisfy(ModManifest.isValidKey) else {
            throw HelperError.failed("the command input contains an invalid state key")
        }
        return input
    }

    // MARK: Serialisation

    /// Runs `body` while holding the mod's lock: a run never sees a snapshot being replaced or
    /// deleted, and two operations on one mod happen one after the other.
    private func exclusively<T>(_ modID: String, _ body: () async throws -> T) async throws -> T {
        await locks.acquire(modID)
        return try await releasing(modID, after: body)
    }

    /// Like `exclusively`, but does not wait for the lock. Commands may hold it for up to an hour; a
    /// change to the snapshot queued behind one would be carried out long after its client gave up
    /// and reported a failure.
    private func unlessBusy<T>(_ modID: String, _ body: () async throws -> T) async throws -> T {
        guard await locks.acquireIfFree(modID) else { throw HelperError.busy }
        return try await releasing(modID, after: body)
    }

    private func releasing<T>(_ modID: String, after body: () async throws -> T) async throws -> T {
        do {
            let value = try await body()
            await locks.release(modID)
            return value
        } catch {
            await locks.release(modID)
            throw error
        }
    }
}

/// One FIFO lock per mod id.
private actor ModLocks {
    /// A key is present while its lock is held; the array holds the waiters in arrival order.
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    func acquire(_ id: String) async {
        guard !acquireIfFree(id) else { return }
        await withCheckedContinuation { waiters[id, default: []].append($0) }
    }

    func acquireIfFree(_ id: String) -> Bool {
        guard waiters[id] == nil else { return false }
        waiters[id] = []
        return true
    }

    func release(_ id: String) {
        guard var queue = waiters[id] else {
            preconditionFailure("released the lock of \(id) without holding it")
        }
        if queue.isEmpty {
            waiters[id] = nil
        } else {
            let next = queue.removeFirst()
            waiters[id] = queue
            next.resume()
        }
    }
}
