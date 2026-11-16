import Foundation
import ToolsyHelperXPC
import ToolsyShared

/// Accepts connections that satisfy the client requirement and come from the helper's user, and serves
/// `HelperXPCProtocol` on them.
final class HelperServer: NSObject, NSXPCListenerDelegate, Sendable {
    let service: HelperService
    /// The user who installed the helper, the only one it works for.
    let clientUID: uid_t
    let activity: Activity
    /// Runs after a successful uninstall has been replied to: unloads the launchd job.
    let removeLaunchdJob: @Sendable () -> Void
    /// Ends the process: when idle, and after an uninstall that failed and left the helper closed.
    let exitProcess: @Sendable () -> Void

    init(
        service: HelperService,
        clientUID: uid_t,
        idleInterval: TimeInterval,
        removeLaunchdJob: @escaping @Sendable () -> Void,
        exitProcess: @escaping @Sendable () -> Void
    ) {
        self.service = service
        self.clientUID = clientUID
        self.activity = Activity(idleInterval: idleInterval, onIdle: exitProcess)
        self.removeLaunchdJob = removeLaunchdJob
        self.exitProcess = exitProcess
    }

    /// The requirement is enforced by the listener itself: a peer that does not satisfy it is
    /// rejected before this delegate is consulted.
    func serve(on listener: NSXPCListener, clientRequirement: String) {
        listener.setConnectionCodeSigningRequirement(clientRequirement)
        listener.delegate = self
        listener.resume()
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // The requirement says which program may connect; this says on whose behalf. The helper was paid for
        // with one user's administrator password and must not hand root to every account that can start the app.
        guard connection.effectiveUserIdentifier == clientUID else { return false }
        let id = activity.openConnection()
        connection.exportedInterface = HelperInterface.make()
        connection.exportedObject = HelperConnection(server: self)
        // Only the connection is forgotten: what it started keeps running (see `Activity`).
        let closed: @Sendable () -> Void = { [activity] in activity.closeConnection(id) }
        connection.interruptionHandler = closed
        connection.invalidationHandler = closed
        connection.resume()
        return true
    }
}

/// The object exported on one connection.
private final class HelperConnection: NSObject, HelperXPCProtocol, Sendable {
    private let server: HelperServer

    init(server: HelperServer) {
        self.server = server
    }

    func hello(reply: @escaping @Sendable (Int) -> Void) {
        reply(HelperConstants.protocolVersion)
    }

    func approvedMods(reply: @escaping @Sendable ([String: String], NSError?) -> Void) {
        perform("approvedMods", fail: { reply([:], $0) }) { service in
            reply(try service.approvedMods(), nil)
        }
    }

    func approve(modID: String, files: [String: Data], executables: [String], reply: @escaping @Sendable (NSError?) -> Void) {
        perform("approve", fail: reply) { service in
            try await service.approve(modID: modID, files: files, executables: executables)
            reply(nil)
        }
    }

    func revoke(modID: String, keepingData: Bool, reply: @escaping @Sendable (NSError?) -> Void) {
        perform("revoke", fail: reply) { service in
            try await service.revoke(modID: modID, keepingData: keepingData)
            reply(nil)
        }
    }

    func run(
        modID: String, command: String, input: Data,
        reply: @escaping @Sendable (Int32, Data, Data, Bool, NSError?) -> Void
    ) {
        perform("run", fail: { reply(-1, Data(), Data(), false, $0) }) { service in
            let result = try await service.run(modID: modID, command: command, input: input)
            reply(result.exitCode, result.stdout, result.stderr, result.timedOut, nil)
        }
    }

    func uninstall(reply: @escaping @Sendable (NSError?) -> Void) {
        guard let current = NSXPCConnection.current() else {
            reply(HelperFailure.rejected.error("uninstall must be called over XPC"))
            return
        }
        let server = server
        switch server.activity.close() {
        case .closed:
            break
        case .busy:
            // Running commands are never killed for this, and their files are not deleted under them.
            reply(HelperFailure.busy.error("a command is still running"))
            return
        case .alreadyClosed:
            // A second request must not delete and unload again beside the first.
            reply(HelperFailure.rejected.error("the helper is being removed"))
            return
        }
        do {
            try server.service.uninstall()
        } catch {
            server.service.logRefusal("uninstall", error)
            reply(HelperFailure.rejected.error(error.localizedDescription))
            // The helper no longer accepts work; the next connection starts a fresh one.
            current.scheduleSendBarrierBlock { server.exitProcess() }
            return
        }
        reply(nil)
        // Unloading the job terminates this process; let the reply leave first.
        current.scheduleSendBarrierBlock { server.removeLaunchdJob() }
    }

    private func perform(
        _ operation: String,
        fail: @escaping @Sendable (NSError) -> Void,
        _ work: @escaping @Sendable (HelperService) async throws -> Void
    ) {
        let service = server.service
        let accepted = server.activity.perform {
            do {
                try await work(service)
            } catch {
                service.logRefusal(operation, error)
                fail(Self.failure(for: error))
            }
        }
        if !accepted {
            fail(HelperFailure.rejected.error("the helper is being removed"))
        }
    }

    private static func failure(for error: any Error) -> NSError {
        switch error {
        case HelperError.notApproved: HelperFailure.notApproved.error("the mod is not approved")
        case HelperError.busy: HelperFailure.busy.error("a command of the mod is still running")
        default: HelperFailure.rejected.error(error.localizedDescription)
        }
    }
}
