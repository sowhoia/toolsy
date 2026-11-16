import Foundation
import Synchronization
import Testing
import ToolsyEngine
import ToolsyShared
@testable import Toolsy

/// A clock that moves only when the test says so.
nonisolated private final class ManualClock: Clock, Sendable {
    struct Instant: InstantProtocol {
        var offset: Duration
        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (left: Instant, right: Instant) -> Bool { left.offset < right.offset }
    }

    private struct Sleeper {
        var deadline: Instant
        var continuation: CheckedContinuation<Void, any Error>
    }

    private let state = Mutex<(now: Instant, sleepers: [UUID: Sleeper])>((Instant(offset: .zero), [:]))

    var now: Instant { state.withLock { $0.now } }
    var minimumResolution: Duration { .zero }
    var sleeping: Int { state.withLock { $0.sleepers.count } }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let outcome: Result<Void, any Error>? = state.withLock { state in
                    if Task.isCancelled { return .failure(CancellationError()) }
                    if deadline <= state.now { return .success(()) }
                    state.sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)
                    return nil
                }
                if let outcome { continuation.resume(with: outcome) }
            }
        } onCancel: {
            state.withLock { $0.sleepers.removeValue(forKey: id) }?.continuation.resume(throwing: CancellationError())
        }
    }

    func advance(by duration: Duration) {
        let due = state.withLock { state in
            state.now = state.now.advanced(by: duration)
            let now = state.now
            let due = state.sleepers.filter { $0.value.deadline <= now }
            for id in due.keys { state.sleepers[id] = nil }
            return due.values.map(\.continuation)
        }
        for continuation in due { continuation.resume() }
    }
}

private actor FakeHelper: PrivilegedExecuting, SystemMaintaining {
    private(set) var calls: [String] = []
    private var helperStatus: HelperStatus
    private var installError: PrivilegedError?
    private var reclaimOutcome: Result<MemoryReclaimReport, PrivilegedError>
    private var heldReclaim: CheckedContinuation<Void, Never>?
    private var holdsReclaim = false

    init(status: HelperStatus = .ready, installError: PrivilegedError? = nil,
         reclaim: Result<MemoryReclaimReport, PrivilegedError> = .success(MemoryReclaimReport(diskCacheFlushed: true, pressureWarningSent: true))) {
        helperStatus = status
        self.installError = installError
        reclaimOutcome = reclaim
    }

    /// The next reclaim waits for `release()`.
    func hold() { holdsReclaim = true }
    var isHolding: Bool { heldReclaim != nil }
    func release() {
        heldReclaim?.resume()
        heldReclaim = nil
        holdsReclaim = false
    }

    func status() -> HelperStatus { helperStatus }

    func install() throws {
        calls.append("install")
        if let installError { throw installError }
        helperStatus = .ready
    }

    func reclaimMemory() async throws -> MemoryReclaimReport {
        calls.append("reclaim")
        if holdsReclaim { await withCheckedContinuation { heldReclaim = $0 } }
        return try reclaimOutcome.get()
    }

    func uninstall() {}
    func approvedMods() -> [String: String] { [:] }
    func approve(modID: String, payload: ModPayload) {}
    func revoke(modID: String, keepingData: Bool) {}
    func run(modID: String, command: String, input: CommandInput) -> CommandResult { CommandResult(exitCode: 0) }
}

private func reading(used: UInt64, free: UInt64) -> MemoryReading {
    MemoryReading(used: used, total: 16 << 30, app: used, wired: 0, compressed: 0, cachedFiles: 2 << 30, free: free,
                  swapUsed: 0, pressure: .normal)
}

/// Memory readings handed out one after the other: before and after the reclaim.
@MainActor
private final class Readings {
    var remaining: [MemoryReading?]
    init(_ readings: [MemoryReading?]) { remaining = readings }
    func next() -> MemoryReading? { remaining.isEmpty ? nil : remaining.removeFirst() }
}

@MainActor
private final class Fixture {
    let root: URL
    let panel = PanelState()
    let helper: FakeHelper
    let store: ModStore
    let clock = ManualClock()
    let readings: Readings
    let optimizer: MemoryOptimizer

    init(_ helper: FakeHelper = FakeHelper(),
         readings: [MemoryReading?] = [reading(used: 10 << 30, free: 1 << 30), reading(used: 9 << 30, free: 3 << 30)]) throws {
        root = FileManager.default.temporaryDirectory.appending(path: "ToolsyTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        self.helper = helper
        let readings = Readings(readings)
        self.readings = readings
        store = ModStore(directories: ToolsyDirectories(root: root), privileged: helper)
        optimizer = MemoryOptimizer(helper: helper, store: store, panel: panel, readMemory: readings.next, clock: clock)
        panel.setVisible(true)
    }

    func waitUntil(_ what: String, _ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !(await condition()) {
            guard ContinuousClock.now < deadline else {
                Issue.record("timed out waiting for \(what)")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Lets the optimizer's next sleep end.
    func pass(_ duration: Duration) async throws {
        try await waitUntil("a sleep") { clock.sleeping == 1 }
        clock.advance(by: duration)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)  // best effort: a temporary folder
    }
}

@MainActor
struct MemoryOptimizerTests {
    @Test func aReadyHelperRunsAtOnceAndTheResultIsMeasured() async throws {
        let fixture = try Fixture()
        let optimizer = fixture.optimizer
        optimizer.optimize()
        #expect(optimizer.phase == .running)
        try await fixture.pass(MemoryOptimizer.settleTime)
        try await fixture.waitUntil("the result") { !optimizer.isBusy }
        guard case .finished(let result) = optimizer.phase else {
            Issue.record("expected a result, got \(optimizer.phase)")
            return
        }
        #expect(result.freed == 2 << 30)
        #expect(result.usedBefore == 10 << 30 && result.usedAfter == 9 << 30)
        #expect(result.report.isComplete)
        #expect(await fixture.helper.calls == ["reclaim"])
        #expect(fixture.panel.dialog == nil)

        // The result goes away by itself after a while.
        try await fixture.pass(MemoryOptimizer.resultLifetime)
        try await fixture.waitUntil("idle") { optimizer.phase == .idle }
    }

    @Test func aMissingHelperIsInstalledAfterAskingThenItRuns() async throws {
        let fixture = try Fixture(FakeHelper(status: .notInstalled))
        let optimizer = fixture.optimizer
        optimizer.optimize()
        try await fixture.waitUntil("the question") { fixture.panel.dialog != nil }
        #expect(optimizer.phase == .asking)
        let question = try #require(fixture.panel.dialog)
        #expect(question.title == String(localized: "Install Toolsy’s helper to free memory?"))
        #expect(question.message?.contains(try #require(ModInterface.passwordNotice(for: .notInstalled))) == true)
        #expect(question.confirmTitle == String(localized: "Install…"))
        fixture.panel.dismissDialog(confirmed: true)

        try await fixture.pass(MemoryOptimizer.settleTime)
        try await fixture.waitUntil("the result") { !optimizer.isBusy }
        guard case .finished = optimizer.phase else {
            Issue.record("expected a result, got \(optimizer.phase)")
            return
        }
        #expect(await fixture.helper.calls == ["install", "reclaim"])
        // Installed through the store, so the mods' view of the helper is current too.
        #expect(fixture.store.helperStatus == .ready)
        #expect(fixture.panel.dialog == nil && fixture.panel.holdCount == 0)
    }

    @Test func anOutdatedHelperIsOfferedAnUpdate() async throws {
        let fixture = try Fixture(FakeHelper(status: .needsUpdate))
        let optimizer = fixture.optimizer
        optimizer.optimize()
        try await fixture.waitUntil("the question") { fixture.panel.dialog != nil }
        #expect(fixture.panel.dialog?.title == String(localized: "Update Toolsy’s helper to free memory?"))
        #expect(fixture.panel.dialog?.confirmTitle == String(localized: "Update…"))
        fixture.panel.dismissDialog(confirmed: false)
        try await fixture.waitUntil("idle") { optimizer.phase == .idle }
    }

    @Test func decliningDoesNothing() async throws {
        let fixture = try Fixture(FakeHelper(status: .notInstalled))
        let optimizer = fixture.optimizer
        optimizer.optimize()
        try await fixture.waitUntil("the question") { fixture.panel.dialog != nil }
        fixture.panel.dismissDialog(confirmed: false)
        try await fixture.waitUntil("idle") { optimizer.phase == .idle }
        #expect(await fixture.helper.calls.isEmpty)
        #expect(fixture.readings.remaining.count == 2)
    }

    @Test func aClosedPanelIsNotAskedAndNothingRuns() async throws {
        // The panel closed between the click and the helper's answer: there is nobody to ask.
        let fixture = try Fixture(FakeHelper(status: .notInstalled))
        fixture.panel.setVisible(false)
        let optimizer = fixture.optimizer
        optimizer.optimize()
        try await fixture.waitUntil("idle") { optimizer.phase == .idle }
        #expect(fixture.panel.dialog == nil)
        #expect(await fixture.helper.calls.isEmpty)
        #expect(fixture.readings.remaining.count == 2)
    }

    @Test func aDismissedPasswordPromptIsAnAnswer() async throws {
        let fixture = try Fixture(FakeHelper(status: .notInstalled, installError: .cancelled))
        let optimizer = fixture.optimizer
        optimizer.optimize()
        try await fixture.waitUntil("the question") { fixture.panel.dialog != nil }
        fixture.panel.dismissDialog(confirmed: true)
        try await fixture.waitUntil("idle") { optimizer.phase == .idle }
        #expect(await fixture.helper.calls == ["install"])
        #expect(fixture.panel.dialog == nil)
    }

    @Test func aFailedInstallIsReported() async throws {
        let fixture = try Fixture(FakeHelper(status: .notInstalled, installError: .rejected("no")))
        let optimizer = fixture.optimizer
        optimizer.optimize()
        try await fixture.waitUntil("the question") { fixture.panel.dialog != nil }
        fixture.panel.dismissDialog(confirmed: true)
        try await fixture.waitUntil("the failure") { !optimizer.isBusy }
        #expect(optimizer.phase == .failed(ModInterface.message(for: .rejected("no"), modName: "")))
        #expect(await fixture.helper.calls == ["install"])
    }

    @Test func aFailingHelperIsReportedInOwnWordsAndClearsByItself() async throws {
        let fixture = try Fixture(FakeHelper(reclaim: .failure(.connection("timed out"))))
        let optimizer = fixture.optimizer
        optimizer.optimize()
        try await fixture.waitUntil("the failure") { !optimizer.isBusy }
        #expect(optimizer.phase == .failed(ModInterface.message(for: .connection("timed out"), modName: "")))
        try await fixture.pass(MemoryOptimizer.resultLifetime)
        try await fixture.waitUntil("idle") { optimizer.phase == .idle }
    }

    @Test func partlyDoneIsSaidSo() async throws {
        let partial = MemoryReclaimReport(diskCacheFlushed: true, pressureWarningSent: false)
        let fixture = try Fixture(FakeHelper(reclaim: .success(partial)))
        let optimizer = fixture.optimizer
        optimizer.optimize()
        try await fixture.pass(MemoryOptimizer.settleTime)
        try await fixture.waitUntil("the result") { !optimizer.isBusy }
        guard case .finished(let result) = optimizer.phase else {
            Issue.record("expected a result, got \(optimizer.phase)")
            return
        }
        #expect(result.report == partial && !result.report.isComplete)
    }

    @Test func nothingDoneIsAFailure() async throws {
        let fixture = try Fixture(FakeHelper(reclaim: .success(MemoryReclaimReport(diskCacheFlushed: false, pressureWarningSent: false))))
        let optimizer = fixture.optimizer
        optimizer.optimize()
        try await fixture.waitUntil("the failure") { !optimizer.isBusy }
        #expect(optimizer.phase == .failed(String(localized: "Memory couldn’t be freed. Try again in a moment.")))
    }

    @Test func lessFreeMemoryAfterwardsIsNothingFreed() async throws {
        let fixture = try Fixture(readings: [reading(used: 10 << 30, free: 3 << 30), reading(used: 11 << 30, free: 1 << 30)])
        let optimizer = fixture.optimizer
        optimizer.optimize()
        try await fixture.pass(MemoryOptimizer.settleTime)
        try await fixture.waitUntil("the result") { !optimizer.isBusy }
        guard case .finished(let result) = optimizer.phase else {
            Issue.record("expected a result, got \(optimizer.phase)")
            return
        }
        #expect(result.freed == 0 && result.usedAfter == 11 << 30)
    }

    @Test func unreadableMemoryIsAFailureBeforeAnythingRuns() async throws {
        let fixture = try Fixture(readings: [nil])
        let optimizer = fixture.optimizer
        optimizer.optimize()
        try await fixture.waitUntil("the failure") { !optimizer.isBusy }
        #expect(optimizer.phase == .failed(String(localized: "Toolsy couldn’t read the memory usage.")))
        #expect(await fixture.helper.calls.isEmpty)
    }

    @Test func aSecondRequestWhileOneRunsIsIgnored() async throws {
        let fixture = try Fixture()
        let optimizer = fixture.optimizer
        await fixture.helper.hold()
        optimizer.optimize()
        try await fixture.waitUntil("the reclaim") { await fixture.helper.isHolding }
        optimizer.optimize()
        optimizer.dismissResult()
        #expect(optimizer.phase == .running)
        await fixture.helper.release()
        try await fixture.pass(MemoryOptimizer.settleTime)
        try await fixture.waitUntil("the result") { !optimizer.isBusy }
        #expect(await fixture.helper.calls == ["reclaim"])

        // A result can be dismissed early, and a new optimisation started.
        optimizer.dismissResult()
        #expect(optimizer.phase == .idle)
        #expect(fixture.clock.sleeping == 0)
    }
}
