import Foundation
import os
import Synchronization
import ToolsyHelperXPC
import ToolsyShared

/// Talks to the privileged helper over XPC and installs it. This is what the app hands the engine.
public struct HelperClient: PrivilegedExecuting, SystemMaintaining {
    struct Configuration: Sendable {
        var installedHelper: URL
        var launchdPlist: URL
        var bundledHelper: URL
        /// A new, not yet resumed connection to the helper.
        var connect: @Sendable () -> NSXPCConnection
        var installLayout: InstallLayout
        /// Runs a shell command as root, showing the administrator prompt.
        var runAsAdministrator: @Sendable (String) async throws -> Void
        var timeouts: Timeouts

        static var production: Configuration {
            Configuration(
                installedHelper: HelperConstants.installedHelper,
                launchdPlist: HelperConstants.launchdPlist,
                bundledHelper: Bundle.main.bundleURL.appending(path: "Contents/\(HelperConstants.bundledHelperPath)"),
                // The privileged bootstrap holds only system daemons: no user process can register this name there.
                connect: { NSXPCConnection(machServiceName: HelperConstants.label, options: .privileged) },
                installLayout: .production,
                runAsAdministrator: AdministratorPrompt.run(shellCommand:),
                timeouts: Timeouts()
            )
        }
    }

    /// Upper bounds on every wait, so a helper that stops answering cannot hang the app.
    struct Timeouts: Sendable {
        /// Includes launchd starting the helper on demand, which can take seconds on a busy Mac; a
        /// premature give-up would make `status()` ask for a needless reinstall.
        var hello: Duration = .seconds(10)
        var operation: Duration = .seconds(30)
        /// Writing up to 64 MB into the store.
        var approve: Duration = .seconds(120)
        /// The longest command timeout, plus the helper's grace period for killing it.
        var run: Duration = .seconds(ModCommand.maxTimeout + 30)
        /// The helper's own timeouts for every step of the reclaim, plus the grace period for each kill.
        var reclaimMemory: Duration = .seconds(180)
        /// From the end of the install script until the new helper answers.
        var startAfterInstall: Duration = .seconds(15)
    }

    let configuration: Configuration
    private static let logger = Logger(subsystem: ToolsyPaths.bundleIdentifier, category: "helper-client")

    /// The client for the helper bundled in the running app.
    public init() {
        self.init(configuration: .production)
    }

    init(configuration: Configuration) {
        self.configuration = configuration
    }

    // MARK: PrivilegedExecuting

    public func status() async -> HelperStatus {
        let files = FileManager.default
        guard files.fileExists(atPath: configuration.launchdPlist.path(percentEncoded: false)),
              files.fileExists(atPath: configuration.installedHelper.path(percentEncoded: false)) else {
            return .notInstalled
        }
        do {
            guard try Data(contentsOf: configuration.installedHelper) == Data(contentsOf: configuration.bundledHelper) else {
                return .needsUpdate
            }
        } catch {
            // Installing again either fixes this or fails with the underlying reason.
            Self.logger.error("cannot compare the installed helper with the bundled one: \(error.localizedDescription, privacy: .public)")
            return .needsUpdate
        }
        // A helper that rejects this build of the app, speaks another protocol or does not answer at
        // all is repaired the same way: by installing again.
        return (try? await hello()) == HelperConstants.protocolVersion ? .ready : .needsUpdate
    }

    public func install() async throws {
        let command = try InstallScript.installCommand(
            layout: configuration.installLayout,
            bundledHelper: configuration.bundledHelper,
            cdhash: CodeIdentity.currentCDHash(),
            clientUID: getuid()
        )
        try await configuration.runAsAdministrator(command)
        let deadline = ContinuousClock.now + configuration.timeouts.startAfterInstall
        var lastError: (any Error)?
        while ContinuousClock.now < deadline {
            do {
                let version = try await hello()
                guard version == HelperConstants.protocolVersion else {
                    throw PrivilegedError.rejected("The installed helper speaks protocol \(version), expected \(HelperConstants.protocolVersion).")
                }
                return
            } catch let error as PrivilegedError where error.isConnectionFailure {
                lastError = error
                try await Task.sleep(for: .milliseconds(250))
            }
        }
        throw PrivilegedError.connection("the helper did not start after installation (\(lastError?.localizedDescription ?? "no answer"))")
    }

    public func uninstall() async throws {
        do {
            try await call(timeout: configuration.timeouts.operation) { helper, finish in
                helper.uninstall { finish(Self.completion($0)) }
            }
        } catch let error as PrivilegedError where error.isConnectionFailure {
            let files = FileManager.default
            let leftovers = [configuration.launchdPlist, configuration.installedHelper, URL(filePath: configuration.installLayout.store)]
            guard leftovers.contains(where: { files.fileExists(atPath: $0.path(percentEncoded: false)) }) else { return }
            Self.logger.notice("the helper cannot remove itself (\(error.localizedDescription, privacy: .public)); asking for an administrator")
            try await configuration.runAsAdministrator(InstallScript.removalCommand(layout: configuration.installLayout))
        }
    }

    public func approvedMods() async throws -> [String: String] {
        try await perform(timeout: configuration.timeouts.operation) { helper, finish in
            helper.approvedMods { digests, error in
                finish(Self.completion(error).map { digests })
            }
        }
    }

    public func approve(modID: String, payload: ModPayload) async throws {
        try await perform(timeout: configuration.timeouts.approve) { helper, finish in
            helper.approve(modID: modID, files: payload.files, executables: payload.executables.sorted()) {
                finish(Self.completion($0, modID: modID))
            }
        }
    }

    public func revoke(modID: String, keepingData: Bool) async throws {
        try await perform(timeout: configuration.timeouts.operation) { helper, finish in
            helper.revoke(modID: modID, keepingData: keepingData) { finish(Self.completion($0, modID: modID)) }
        }
    }

    public func run(modID: String, command: String, input: CommandInput) async throws -> CommandResult {
        let data: Data
        do {
            data = try JSONEncoder().encode(input)
        } catch {
            throw PrivilegedError.rejected("The command input cannot be encoded: \(error.localizedDescription)")
        }
        return try await perform(timeout: configuration.timeouts.run) { helper, finish in
            helper.run(modID: modID, command: command, input: data) { exitCode, stdout, stderr, timedOut, error in
                finish(Self.completion(error, modID: modID).map {
                    CommandResult(exitCode: exitCode, stdout: stdout, stderr: stderr, timedOut: timedOut)
                })
            }
        }
    }

    // MARK: SystemMaintaining

    public func reclaimMemory() async throws -> MemoryReclaimReport {
        try await perform(timeout: configuration.timeouts.reclaimMemory) { helper, finish in
            helper.reclaimMemory { flushed, warned, error in
                finish(Self.completion(error).map { MemoryReclaimReport(diskCacheFlushed: flushed, pressureWarningSent: warned) })
            }
        }
    }

    // MARK: Calls

    private func hello() async throws -> Int {
        try await call(timeout: configuration.timeouts.hello) { helper, finish in
            helper.hello { finish(.success($0)) }
        }
    }

    /// A call whose connection failure is reported as `.helperUnavailable` when the helper turns out to
    /// be missing or outdated, which is what the app can act on.
    private func perform<Value: Sendable>(
        timeout: Duration,
        _ send: (any HelperXPCProtocol, @escaping @Sendable (Result<Value, PrivilegedError>) -> Void) -> Void
    ) async throws -> Value {
        do {
            return try await call(timeout: timeout, send)
        } catch let error as PrivilegedError where error.isConnectionFailure {
            let status = await status()
            throw status == .ready ? error : PrivilegedError.helperUnavailable(status)
        }
    }

    /// Sends one message on a fresh connection and waits for exactly one outcome: the reply, a
    /// connection error, the timeout or cancellation of the calling task, whichever comes first.
    /// Giving up only stops waiting: the helper finishes what it started and drops the reply.
    private func call<Value: Sendable>(
        timeout: Duration,
        _ send: (any HelperXPCProtocol, @escaping @Sendable (Result<Value, PrivilegedError>) -> Void) -> Void
    ) async throws -> Value {
        let connection = configuration.connect()
        connection.remoteObjectInterface = HelperInterface.make()
        let pending = PendingCall<Value>(connection: connection)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard pending.start(continuation) else { return }
                connection.resume()
                let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                    pending.finish(.failure(PrivilegedError.connection(error.localizedDescription)))
                }
                guard let helper = proxy as? any HelperXPCProtocol else {
                    pending.finish(.failure(PrivilegedError.connection("the connection has no helper interface")))
                    return
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout.timeInterval) {
                    pending.finish(.failure(PrivilegedError.connection("the helper did not answer within \(timeout)")))
                }
                send(helper) { pending.finish($0.mapError { $0 }) }
            }
        } onCancel: {
            pending.finish(.failure(CancellationError()))
        }
    }

    private static func completion(_ error: NSError?, modID: String = "") -> Result<Void, PrivilegedError> {
        guard let error else { return .success(()) }
        guard error.domain == HelperFailure.domain else {
            return .failure(.connection(error.localizedDescription))
        }
        switch HelperFailure(rawValue: error.code) {
        case .notApproved: return .failure(.notApproved(modID: modID))
        case .busy: return .failure(.busy)
        case .rejected, nil: return .failure(.rejected(error.localizedDescription))
        }
    }
}

/// The state of one call, shared by the reply, the error handler, the timer and cancellation.
/// The first outcome resumes the continuation and invalidates the connection; later ones do nothing.
private final class PendingCall<Value: Sendable>: Sendable {
    private struct State {
        var continuation: CheckedContinuation<Value, any Error>?
        var finished = false
    }

    private let state = Mutex(State())
    // NSXPCConnection is not marked Sendable, but `invalidate` may be called from any thread; it is
    // the only thing done with it here.
    nonisolated(unsafe) private let connection: NSXPCConnection

    init(connection: NSXPCConnection) {
        self.connection = connection
    }

    /// Returns false when the call was already cancelled, in which case the continuation has been resumed.
    func start(_ continuation: CheckedContinuation<Value, any Error>) -> Bool {
        let alreadyFinished = state.withLock { state in
            if !state.finished { state.continuation = continuation }
            return state.finished
        }
        if alreadyFinished {
            connection.invalidate()
            continuation.resume(throwing: CancellationError())
        }
        return !alreadyFinished
    }

    func finish(_ result: Result<Value, any Error>) {
        let continuation = state.withLock { state -> CheckedContinuation<Value, any Error>? in
            guard !state.finished else { return nil }
            state.finished = true
            // Nil when cancelled before `start`, which then resumes it.
            return state.continuation.take()
        }
        guard let continuation else { return }
        connection.invalidate()
        continuation.resume(with: result)
    }
}

extension PrivilegedError {
    /// The helper could not be reached or did not answer, as opposed to answering with a refusal.
    var isConnectionFailure: Bool {
        if case .connection = self { true } else { false }
    }
}

extension Duration {
    var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}
