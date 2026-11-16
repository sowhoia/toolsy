import Foundation
import Synchronization

/// Tracks open connections and running operations. It decides when the helper is idle (and exits,
/// so launchd starts it again on the next connection) and whether it may be uninstalled.
///
/// Operations are never cancelled, not when their client goes away and not for an uninstall: a
/// privileged command that has started runs to completion or to its own manifest timeout, because
/// killing a root program halfway through changing system state is worse than letting it finish.
/// A reply to a client that has gone is simply dropped, and an uninstall is refused while anything runs.
final class Activity: Sendable {
    typealias ConnectionID = Int

    private struct State {
        var nextConnection = 0
        /// A set rather than a count, so that closing a connection twice is harmless.
        var connections: Set<ConnectionID> = []
        var operations = 0
        var closed = false
        /// Bumped on every change, so a pending idle check knows whether anything happened meanwhile.
        var generation = 0

        var isIdle: Bool { connections.isEmpty && operations == 0 && !closed }
    }

    private let state = Mutex(State())
    private let idleInterval: TimeInterval
    private let onIdle: @Sendable () -> Void

    /// `onIdle` runs once nothing has happened for `idleInterval` seconds, counting from now.
    init(idleInterval: TimeInterval, onIdle: @escaping @Sendable () -> Void) {
        self.idleInterval = idleInterval
        self.onIdle = onIdle
        scheduleIdleCheck(generation: 0)
    }

    func openConnection() -> ConnectionID {
        state.withLock { state in
            state.generation += 1
            state.nextConnection += 1
            state.connections.insert(state.nextConnection)
            return state.nextConnection
        }
    }

    /// Operations the connection started keep running; see the type's documentation.
    func closeConnection(_ connection: ConnectionID) {
        let generation = state.withLock { state in
            state.generation += 1
            state.connections.remove(connection)
            return state.isIdle ? state.generation : nil
        }
        if let generation { scheduleIdleCheck(generation: generation) }
    }

    /// Starts `work` as an operation. Returns false, without running it, once the helper is shutting down.
    func perform(_ work: @escaping @Sendable () async -> Void) -> Bool {
        let accepted = state.withLock { state in
            guard !state.closed else { return false }
            state.generation += 1
            state.operations += 1
            return true
        }
        if accepted {
            Task {
                await work()
                finish()
            }
        }
        return accepted
    }

    enum Closing {
        case closed
        /// An operation is running; nothing changed.
        case busy
        /// An earlier call closed it already.
        case alreadyClosed
    }

    /// Refuses every operation from now on, for the uninstall that follows; only the call that gets
    /// `.closed` may uninstall. While an operation is running nothing changes: waiting for it instead
    /// would outlast the client's patience, which would then take the silence for a dead helper.
    func close() -> Closing {
        state.withLock { state in
            guard !state.closed else { return .alreadyClosed }
            guard state.operations == 0 else { return .busy }
            state.closed = true
            state.generation += 1
            return .closed
        }
    }

    private func finish() {
        let generation = state.withLock { state in
            state.generation += 1
            state.operations -= 1
            return state.isIdle ? state.generation : nil
        }
        if let generation { scheduleIdleCheck(generation: generation) }
    }

    private func scheduleIdleCheck(generation: Int) {
        DispatchQueue.global().asyncAfter(deadline: .now() + idleInterval) { [self] in
            // Called under the lock so that no connection can register between the check and the exit.
            state.withLock { state in
                if state.generation == generation && state.isIdle { onIdle() }
            }
        }
    }
}
