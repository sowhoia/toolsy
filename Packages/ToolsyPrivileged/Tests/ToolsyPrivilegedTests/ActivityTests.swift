import Foundation
import Testing
@testable import ToolsyHelperCore

@Suite struct ActivityTests {
    private let idled = Locked(0)

    private func makeActivity(interval: TimeInterval = 0.2) -> Activity {
        let idled = idled
        return Activity(idleInterval: interval) { idled.withLock { $0 += 1 } }
    }

    private var idleCount: Int { idled.withLock { $0 } }

    @Test func exitsWhenNothingHappens() async throws {
        _ = makeActivity()
        #expect(try await eventually(within: .seconds(2)) { idleCount == 1 })
        try await Task.sleep(for: .milliseconds(500))
        #expect(idleCount == 1)
    }

    @Test func anOpenConnectionKeepsItAlive() async throws {
        let activity = makeActivity()
        let connection = activity.openConnection()
        try await Task.sleep(for: .milliseconds(600))
        #expect(idleCount == 0)
        activity.closeConnection(connection)
        #expect(try await eventually(within: .seconds(2)) { idleCount == 1 })
    }

    @Test func anOperationInProgressKeepsItAlive() async throws {
        let activity = makeActivity()
        let connection = activity.openConnection()
        let release = Locked<CheckedContinuation<Void, Never>?>(nil)
        #expect(activity.perform {
            await withCheckedContinuation { continuation in release.withLock { $0 = continuation } }
        })
        #expect(try await eventually { release.withLock { $0 != nil } })
        activity.closeConnection(connection)
        try await Task.sleep(for: .milliseconds(600))
        #expect(idleCount == 0)
        release.withLock { $0?.resume() }
        #expect(try await eventually(within: .seconds(2)) { idleCount == 1 })
    }

    @Test func closingAConnectionLetsItsOperationsFinish() async throws {
        let activity = makeActivity(interval: 0.2)
        let connection = activity.openConnection()
        let outcome = Locked<String?>(nil)
        #expect(activity.perform {
            do {
                try await Task.sleep(for: .milliseconds(500))
                outcome.withLock { $0 = "finished" }
            } catch {
                outcome.withLock { $0 = "cancelled" }
            }
        })
        activity.closeConnection(connection)
        activity.closeConnection(connection)
        #expect(try await eventually { outcome.withLock { $0 } != nil })
        #expect(outcome.withLock { $0 } == "finished")
        // The operation kept the process alive until it ended; idle counts from then.
        #expect(idleCount == 0)
        #expect(try await eventually(within: .seconds(2)) { idleCount == 1 })
    }

    @Test func closesOnlyWhenNothingRunsAndThenRefusesWork() async throws {
        let activity = makeActivity(interval: 0.2)
        let finished = Locked(false)
        #expect(activity.perform {
            try? await Task.sleep(for: .milliseconds(300))
            finished.withLock { $0 = !Task.isCancelled }
        })
        // Not while the operation runs; it goes on undisturbed, and so does everything else.
        #expect(activity.close() == .busy)
        #expect(activity.perform {})
        #expect(try await eventually { finished.withLock { $0 } })
        #expect(try await eventually { activity.close() == .closed })
        // Only that one call may go on to uninstall.
        #expect(activity.close() == .alreadyClosed)
        #expect(!activity.perform { Issue.record("ran after closing") })
        // The helper is uninstalling; it must not exit on its own meanwhile.
        try await Task.sleep(for: .milliseconds(600))
        #expect(idleCount == 0)
    }
}
