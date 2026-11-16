import Foundation
import Testing
@testable import ToolsyHelperClient
@testable import ToolsyHelperCore
import ToolsyHelperXPC
import ToolsyShared

@Suite struct XPCTests {
    @Test func everyOperationRoundTrips() async throws {
        let helper = try InProcessHelper(clientRequirement: try ownRequirement())
        let client = helper.client()
        #expect(await client.status() == .ready)
        #expect(try await client.approvedMods().isEmpty)

        let payload = try ProbeMod.payload()
        try await client.approve(modID: ProbeMod.id, payload: payload)
        #expect(try await client.approvedMods() == [ProbeMod.id: payload.digest])

        let result = try await client.run(modID: ProbeMod.id, command: "env", input: ProbeMod.input("env", key: "level", value: 3))
        #expect(result.succeeded && !result.timedOut)
        let output = keyValues(result.stdout)
        #expect(output["TOOLSY_MOD_DIR"] == helper.store.snapshotDirectory(ProbeMod.id).path(percentEncoded: false))
        #expect(output["TOOLSY_VALUE"] == "3")
        let echoed = try await client.run(modID: ProbeMod.id, command: "echo", input: ProbeMod.input("echo"))
        #expect(echoed.succeeded && !echoed.stdout.isEmpty)

        await #expect(throws: PrivilegedError.notApproved(modID: "unknown")) {
            try await client.run(modID: "unknown", command: "env", input: ProbeMod.input("env"))
        }
        await #expect(throws: PrivilegedError.rejected("probe/plain is not a privileged command")) {
            try await client.run(modID: ProbeMod.id, command: "plain", input: ProbeMod.input("plain"))
        }
        await #expect(throws: PrivilegedError.rejected("mod.json declares the id probe, not other")) {
            try await client.approve(modID: "other", payload: payload)
        }

        try await client.revoke(modID: ProbeMod.id, keepingData: false)
        #expect(try await client.approvedMods().isEmpty)

        try await client.uninstall()
        for removed in [helper.store.root, helper.plist, helper.installedHelper] {
            #expect(!FileManager.default.fileExists(atPath: removed.path(percentEncoded: false)))
        }
        #expect(try await eventually { helper.removedJob.withLock { $0 } == 1 })
        #expect(await client.status() == .notInstalled)
    }

    @Test func aHelperInstalledByAnotherUserIsNotThisUsers() async throws {
        let helper = try InProcessHelper(clientRequirement: try ownRequirement(), clientUID: getuid() + 1)
        let client = helper.client()
        // The right program, but not the user who paid for the helper with an administrator password.
        #expect(await client.status() == .needsUpdate)
        await #expect(throws: PrivilegedError.helperUnavailable(.needsUpdate)) {
            try await client.approve(modID: ProbeMod.id, payload: try ProbeMod.payload())
        }
        #expect(try helper.server.service.approvedMods().isEmpty)
    }

    @Test func aPeerThatDoesNotSatisfyTheRequirementIsRejected() async throws {
        let helper = try InProcessHelper(clientRequirement: requirement(cdhash: String(repeating: "0", count: 40)))
        let client = helper.client()
        let started = ContinuousClock.now
        #expect(await client.status() == .needsUpdate)
        await #expect(throws: PrivilegedError.helperUnavailable(.needsUpdate)) {
            try await client.approve(modID: ProbeMod.id, payload: try ProbeMod.payload())
        }
        // Rejected by the listener, not merely timed out.
        #expect(ContinuousClock.now - started < .seconds(2))
        #expect(try helper.server.service.approvedMods().isEmpty)
    }

    @Test func aHelperThatStopsAnsweringDoesNotHangTheClient() async throws {
        let fake = try FakeHelper(SilentHelper())
        let client = fake.client(timeouts: .short)
        let started = ContinuousClock.now
        #expect(await client.status() == .needsUpdate)
        await #expect(throws: PrivilegedError.helperUnavailable(.needsUpdate)) {
            try await client.run(modID: ProbeMod.id, command: "env", input: ProbeMod.input("env"))
        }
        #expect(ContinuousClock.now - started < .seconds(4))
    }

    @Test func aConnectionThatDiesMidRequestFailsTheCall() async throws {
        let fake = try FakeHelper(HangingUpHelper())
        let client = fake.client()
        #expect(await client.status() == .ready)
        let started = ContinuousClock.now
        let error = await #expect(throws: PrivilegedError.self) {
            try await client.run(modID: ProbeMod.id, command: "env", input: ProbeMod.input("env"))
        }
        #expect(error?.isConnectionFailure == true)
        #expect(ContinuousClock.now - started < .seconds(2))
    }

    @Test func anIncompatibleHelperNeedsAnUpdate() async throws {
        let fake = try FakeHelper(SilentHelper(version: HelperConstants.protocolVersion + 1))
        #expect(await fake.client().status() == .needsUpdate)
    }

    @Test func aCommandOutlivesTheClientThatStartedIt() async throws {
        // A short idle interval: the helper would exit during the command if the command did not count.
        let helper = try InProcessHelper(clientRequirement: try ownRequirement(), idleInterval: 0.3)
        let client = helper.client()
        try await client.approve(modID: ProbeMod.id, payload: try ProbeMod.payload())
        let data = helper.store.dataDirectory(ProbeMod.id)
        let started = data.appending(path: "started").path(percentEncoded: false)
        let finished = data.appending(path: "finished").path(percentEncoded: false)

        let running = Task { try await client.run(modID: ProbeMod.id, command: "settle", input: ProbeMod.input("settle")) }
        #expect(try await eventually { FileManager.default.fileExists(atPath: started) })
        // Cancelling makes the client give up and invalidate its connection mid-run.
        running.cancel()
        await #expect(throws: CancellationError.self) { try await running.value }
        #expect(!FileManager.default.fileExists(atPath: finished))

        #expect(try await eventually { FileManager.default.fileExists(atPath: finished) })
        #expect(helper.exited.withLock { $0 } == 0)
        // Once the command is done and nobody is connected, the helper goes idle as usual.
        #expect(try await eventually { helper.exited.withLock { $0 } == 1 })
    }

    @Test func nothingIsRemovedOrReplacedUnderARunningCommand() async throws {
        let helper = try InProcessHelper(clientRequirement: try ownRequirement())
        // This client fails the test if it ever falls back to the administrator prompt.
        let client = helper.client()
        try await client.approve(modID: ProbeMod.id, payload: try ProbeMod.payload())
        let started = helper.store.dataDirectory(ProbeMod.id).appending(path: "started").path(percentEncoded: false)
        let running = Task { try await client.run(modID: ProbeMod.id, command: "settle", input: ProbeMod.input("settle")) }
        #expect(try await eventually { FileManager.default.fileExists(atPath: started) })

        // The helper answers at once instead of making its client wait for the command.
        let asked = ContinuousClock.now
        await #expect(throws: PrivilegedError.busy) { try await client.uninstall() }
        await #expect(throws: PrivilegedError.busy) { try await client.revoke(modID: ProbeMod.id, keepingData: false) }
        await #expect(throws: PrivilegedError.busy) {
            try await client.approve(modID: ProbeMod.id, payload: try ProbeMod.payload(version: "2"))
        }
        #expect(ContinuousClock.now - asked < .milliseconds(700))
        // Other mods are not held up.
        try await client.approve(modID: "other", payload: try ProbeMod.payload(id: "other"))

        let result = try await running.value
        #expect(result.exitCode == 0 && !result.timedOut)
        #expect(try await client.approvedMods()[ProbeMod.id] == (try ProbeMod.payload().digest))

        // The reply to `run` leaves a moment before the helper stops counting the command.
        var removed = false
        for _ in 0..<100 where !removed {
            do {
                try await client.uninstall()
                removed = true
            } catch PrivilegedError.busy {
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        #expect(removed)
        #expect(!FileManager.default.fileExists(atPath: helper.store.root.path(percentEncoded: false)))
        #expect(try await eventually { helper.removedJob.withLock { $0 } == 1 })
        // A closed helper refuses further work instead of recreating the store.
        await #expect(throws: PrivilegedError.rejected("the helper is being removed")) {
            try await client.revoke(modID: ProbeMod.id, keepingData: false)
        }
    }

    @Test func onlyOneOfTwoRemovalsRemoves() async throws {
        let helper = try InProcessHelper(clientRequirement: try ownRequirement())
        let client = helper.client()
        try await client.approve(modID: ProbeMod.id, payload: try ProbeMod.payload())
        @Sendable func removal() async -> String {
            do {
                try await client.uninstall()
                return "removed"
            } catch {
                return error.localizedDescription
            }
        }
        async let first = removal(), second = removal()
        // Whichever came second found the helper already closing and left everything to the first.
        #expect(await [first, second].sorted() == ["removed", "the helper is being removed"])
        #expect(try await eventually { helper.removedJob.withLock { $0 } == 1 })
        try await Task.sleep(for: .milliseconds(200))
        #expect(helper.removedJob.withLock { $0 } == 1 && helper.exited.withLock { $0 } == 0)
    }

    @Test func concurrentCallsEachGetTheirOwnReply() async throws {
        let helper = try InProcessHelper(clientRequirement: try ownRequirement())
        let client = helper.client()
        for id in ["a", "b", "c"] {
            try await client.approve(modID: id, payload: try ProbeMod.payload(id: id))
        }
        try await withThrowingTaskGroup { group in
            for round in 0..<30 {
                let id = ["a", "b", "c"][round % 3]
                group.addTask {
                    let output = keyValues(try await client.run(modID: id, command: "env", input: ProbeMod.input("env", value: .number(Double(round)))).stdout)
                    #expect(output["TOOLSY_MOD_ID"] == id && output["TOOLSY_VALUE"] == "\(round)")
                }
            }
            try await group.waitForAll()
        }
    }
}

/// An anonymous listener exporting a stand-in for the helper, with no code requirement.
final class FakeHelper: NSObject, NSXPCListenerDelegate {
    let listener = NSXPCListener.anonymous()
    let exported: any HelperXPCProtocol & NSObject
    let directory: TemporaryDirectory
    let installedHelper: URL
    let plist: URL

    init(_ exported: any HelperXPCProtocol & NSObject) throws {
        self.exported = exported
        directory = try TemporaryDirectory()
        installedHelper = try directory.write("helper binary", to: "helper")
        plist = try directory.write("plist", to: "test.plist")
        super.init()
        listener.delegate = self
        listener.resume()
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = HelperInterface.make()
        connection.exportedObject = exported
        connection.resume()
        return true
    }

    func client(timeouts: HelperClient.Timeouts = HelperClient.Timeouts()) -> HelperClient {
        let endpoint = listener.endpoint
        return HelperClient(configuration: HelperClient.Configuration(
            installedHelper: installedHelper, launchdPlist: plist, bundledHelper: installedHelper,
            connect: { NSXPCConnection(listenerEndpoint: endpoint) },
            installLayout: .production,
            runAsAdministrator: { _ in Issue.record("unexpected administrator prompt") },
            timeouts: timeouts
        ))
    }
}

/// Answers `hello` (with any version) and nothing else; keeps the reply blocks so none is released unanswered.
final class SilentHelper: NSObject, HelperXPCProtocol, Sendable {
    private let version: Int?
    private let retained = Locked<[any Sendable]>([])

    init(version: Int? = nil) {
        self.version = version
    }

    func hello(reply: @escaping @Sendable (Int) -> Void) {
        if let version { reply(version) } else { keep(reply) }
    }

    func approvedMods(reply: @escaping @Sendable ([String: String], NSError?) -> Void) { keep(reply) }
    func approve(modID: String, files: [String: Data], executables: [String], reply: @escaping @Sendable (NSError?) -> Void) { keep(reply) }
    func revoke(modID: String, keepingData: Bool, reply: @escaping @Sendable (NSError?) -> Void) { keep(reply) }
    func run(modID: String, command: String, input: Data, reply: @escaping @Sendable (Int32, Data, Data, Bool, NSError?) -> Void) { keep(reply) }
    func uninstall(reply: @escaping @Sendable (NSError?) -> Void) { keep(reply) }

    private func keep(_ reply: any Sendable) {
        retained.withLock { $0.append(reply) }
    }
}

/// Answers `hello`, then drops the connection in the middle of any other request.
final class HangingUpHelper: NSObject, HelperXPCProtocol, Sendable {
    func hello(reply: @escaping @Sendable (Int) -> Void) { reply(HelperConstants.protocolVersion) }
    func approvedMods(reply: @escaping @Sendable ([String: String], NSError?) -> Void) { hangUp() }
    func approve(modID: String, files: [String: Data], executables: [String], reply: @escaping @Sendable (NSError?) -> Void) { hangUp() }
    func revoke(modID: String, keepingData: Bool, reply: @escaping @Sendable (NSError?) -> Void) { hangUp() }
    func run(modID: String, command: String, input: Data, reply: @escaping @Sendable (Int32, Data, Data, Bool, NSError?) -> Void) { hangUp() }
    func uninstall(reply: @escaping @Sendable (NSError?) -> Void) { hangUp() }

    private func hangUp() {
        NSXPCConnection.current()?.invalidate()
    }
}
