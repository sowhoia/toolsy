import Foundation
import Observation
import Synchronization
import Testing
@testable import ToolsyEngine
import ToolsyShared

/// A scratch directory removed when the test ends.
final class TemporaryDirectory: Sendable {
    let url: URL

    init() throws {
        url = URL.temporaryDirectory.appending(path: "toolsy-engine-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    @discardableResult
    func write(_ contents: String, to relativePath: String, executable: Bool = false) throws -> URL {
        let file = url.appending(path: relativePath)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: file.path(percentEncoded: false))
        return file
    }
}

/// A manifest with the required fields; `extra` is spliced into the top-level object.
func manifest(id: String = "demo", name: String = "Demo", version: String = "1.0", _ extra: String = "") -> String {
    #"{"schema": 1, "id": "\#(id)", "name": "\#(name)", "version": "\#(version)""# + (extra.isEmpty ? "" : ", " + extra) + "}"
}

/// Writes a mod folder: `mod.json` plus `/bin/sh` scripts (made executable) under their relative paths.
@discardableResult
func writeMod(_ manifestJSON: String, scripts: [String: String] = [:], in directory: TemporaryDirectory, folder: String = "source") throws -> URL {
    let root = directory.url.appending(path: folder, directoryHint: .isDirectory)
    try? FileManager.default.removeItem(at: root)
    try directory.write(manifestJSON, to: "\(folder)/mod.json")
    for (path, body) in scripts {
        try directory.write("#!/bin/sh\n" + body + "\n", to: "\(folder)/\(path)", executable: true)
    }
    return root
}

struct TimedOut: Error {}

/// Polls `condition` until it holds; fails the test after `timeout`.
///
/// The deadline is generous on purpose: macOS scans every freshly written script on its first launch,
/// and when the whole suite runs in parallel those scans queue up for seconds. A condition that holds
/// returns at once, so a long deadline costs nothing on a quiet machine.
@MainActor
func eventually(
    _ what: String, timeout: Duration = .seconds(30),
    sourceLocation: SourceLocation = #_sourceLocation, _ condition: () throws -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while try !condition() {
        guard ContinuousClock.now < deadline else {
            Issue.record("timed out waiting for \(what)", sourceLocation: sourceLocation)
            throw TimedOut()
        }
        try await Task.sleep(for: .milliseconds(5))
    }
}

/// Waits until the fake helper has received `call`; fails the test after `timeout`.
@MainActor
func waitUntil(_ helper: FakeHelper, received call: String, timeout: Duration = .seconds(30),
               sourceLocation: SourceLocation = #_sourceLocation) async throws {
    let deadline = ContinuousClock.now + timeout
    while await !helper.calls.contains(call) {
        guard ContinuousClock.now < deadline else {
            Issue.record("timed out waiting for the helper to receive \(call)", sourceLocation: sourceLocation)
            throw TimedOut()
        }
        try await Task.sleep(for: .milliseconds(5))
    }
}

func isAlive(_ pid: Int32) -> Bool {
    kill(pid, 0) == 0
}

/// Records every call and answers like a helper whose state the test controls.
actor FakeHelper: PrivilegedExecuting {
    var helperStatus: HelperStatus
    var approvals: [String: String] = [:]
    private(set) var calls: [String] = []
    private(set) var inputs: [CommandInput] = []
    var result = CommandResult(exitCode: 0, stdout: Data(#"{"status": "as root"}"#.utf8))
    /// Thrown by the next `run`, then cleared.
    var runError: PrivilegedError?
    /// Thrown by the next `install`, then cleared: the user dismissing the administrator prompt, say.
    var installError: PrivilegedError?
    /// Thrown by the next calls of `approve`, one each.
    var approveErrors: [PrivilegedError] = []
    /// Thrown by the next calls of `revoke`, one each.
    var revokeErrors: [PrivilegedError] = []
    /// How long the next calls of `revoke` take, one each.
    var revokeDelays: [Duration] = []
    /// Runs inside `approve`, once the approval is recorded.
    var afterApprove: (@Sendable () async -> Void)?
    /// How long the next calls of `run` take, one each. Like a root command they cannot be cancelled,
    /// and they note "done <mod> <command>" when they end.
    var runDelays: [Duration] = []

    init(status: HelperStatus = .notInstalled) {
        helperStatus = status
    }

    func set(status: HelperStatus) { helperStatus = status }
    func set(approval digest: String?, for id: String) { approvals[id] = digest }
    func set(runError: PrivilegedError?) { self.runError = runError }
    func set(installError: PrivilegedError?) { self.installError = installError }
    func set(approveErrors: [PrivilegedError]) { self.approveErrors = approveErrors }
    func set(revokeErrors: [PrivilegedError]) { self.revokeErrors = revokeErrors }
    func set(revokeDelays: [Duration]) { self.revokeDelays = revokeDelays }
    func set(afterApprove: (@Sendable () async -> Void)?) { self.afterApprove = afterApprove }
    func set(runDelays: [Duration]) { self.runDelays = runDelays }
    func set(result: CommandResult) { self.result = result }

    func status() async -> HelperStatus { helperStatus }

    func install() async throws {
        calls.append("install")
        if let installError {
            self.installError = nil
            throw installError
        }
        helperStatus = .ready
    }

    func uninstall() async throws {
        calls.append("uninstall")
        helperStatus = .notInstalled
        approvals = [:]
    }

    func approvedMods() async throws -> [String: String] {
        guard helperStatus == .ready else { throw PrivilegedError.helperUnavailable(helperStatus) }
        return approvals
    }

    func approve(modID: String, payload: ModPayload) async throws {
        calls.append("approve \(modID)")
        if !approveErrors.isEmpty {
            throw approveErrors.removeFirst()
        }
        approvals[modID] = payload.digest
        await afterApprove?()
    }

    func revoke(modID: String, keepingData: Bool) async throws {
        calls.append("revoke \(modID)" + (keepingData ? ", data kept" : ""))
        if !revokeDelays.isEmpty {
            try await Task.sleep(for: revokeDelays.removeFirst())
        }
        if !revokeErrors.isEmpty {
            throw revokeErrors.removeFirst()
        }
        approvals[modID] = nil
    }

    func run(modID: String, command: String, input: CommandInput) async throws -> CommandResult {
        calls.append("run \(modID) \(command)")
        inputs.append(input)
        if !runDelays.isEmpty {
            let delay = runDelays.removeFirst()
            // A task of its own, so cancelling the caller does not cut the wait short.
            await Task { try? await Task.sleep(for: delay) }.value
            calls.append("done \(modID) \(command)")
        }
        if let runError {
            self.runError = nil
            throw runError
        }
        return result
    }
}

/// A clock the test advances by hand, for the engine's rate limits.
final class ManualClock: Sendable {
    private let origin = ContinuousClock.now
    private let elapsed = Mutex(Duration.zero)

    var now: ContinuousClock.Instant { origin + elapsed.withLock { $0 } }

    func advance(by duration: Duration) {
        elapsed.withLock { $0 += duration }
    }
}

/// A store over a temporary root with compressed timing. Use through `withHarness`.
@MainActor
final class Harness {
    let temporary: TemporaryDirectory
    let directories: ToolsyDirectories
    let helper: FakeHelper
    let timing: EngineTiming
    let languages: [String]
    private(set) var store: ModStore

    init(scale: Double, helper: FakeHelper, clock: ManualClock? = nil, languages: [String] = []) throws {
        temporary = try TemporaryDirectory()
        directories = ToolsyDirectories(root: temporary.url.appending(path: "Toolsy", directoryHint: .isDirectory))
        self.helper = helper
        var timing = EngineTiming(scale: scale)
        if let clock {
            timing.now = { clock.now }
        }
        self.timing = timing
        self.languages = languages
        store = ModStore(directories: directories, privileged: helper, languages: languages, timing: timing)
    }

    /// Writes a mod folder and installs it through prepare + commit.
    @discardableResult
    func install(_ manifestJSON: String, scripts: [String: String] = [:]) async throws -> Mod {
        let source = try writeMod(manifestJSON, scripts: scripts, in: temporary)
        return try await store.commitInstall(store.prepareInstall(from: source))
    }

    /// Shuts the store down and starts a new one over the same directories, as an app relaunch does.
    func relaunch() async {
        await store.shutdown()
        store = ModStore(directories: directories, privileged: helper, languages: languages, timing: timing)
        await store.start()
    }

    func mod(_ id: String = "demo") throws -> Mod {
        try #require(store.mods.first { $0.id == id })
    }

    /// Lines a fixture script appended to `$TOOLSY_DATA_DIR/log`.
    func log(of id: String = "demo") -> [String] {
        let file = directories.data.appending(path: "\(id)/log")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init)
    }
}

/// Runs `body` against a fresh started store and always shuts it down, so no test leaves processes behind.
@MainActor
func withHarness(
    scale: Double = 0.01, helper: FakeHelper = FakeHelper(), clock: ManualClock? = nil, languages: [String] = [],
    _ body: (Harness) async throws -> Void
) async throws {
    let harness = try Harness(scale: scale, helper: helper, clock: clock, languages: languages)
    await harness.store.start()
    do {
        try await body(harness)
    } catch {
        await harness.store.shutdown()
        throw error
    }
    await harness.store.shutdown()
}

/// Appends its words to the mod's log: `log "$TOOLSY_EVENT" "$TOOLSY_VALUE"`.
let logLine = #"log() { echo "$*" >> "$TOOLSY_DATA_DIR/log"; }"#

/// Whether something `read` reads changes while `body` runs, as SwiftUI would see it.
@MainActor
func changes(_ read: () -> Void, during body: () async throws -> Void) async rethrows -> Bool {
    let changed = Flag()
    withObservationTracking(read) { changed.raise() }
    try await body()
    return changed.isRaised
}

final class Flag: Sendable {
    private let raised = Mutex(false)

    var isRaised: Bool { raised.withLock { $0 } }

    func raise() {
        raised.withLock { $0 = true }
    }
}

/// Collects what `ModStore.notificationHandler` receives.
@MainActor
final class Inbox {
    private(set) var notifications: [ModNotification] = []

    /// Title and body of each notification.
    var texts: [[String]] { notifications.map { [$0.title, $0.body] } }

    init(_ store: ModStore) {
        store.notificationHandler = { [weak self] in self?.notifications.append($0) }
    }
}
