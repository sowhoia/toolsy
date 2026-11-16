import Foundation
import Testing
import ToolsyEngine
import ToolsyShared
import UserNotifications
@testable import Toolsy

/// Notification Centre as the tests need it: the user's answer to the permission prompt is decided up front.
private final class FakeCenter: UserNotificationCenter {
    var status: UNAuthorizationStatus
    let answer: Bool
    private(set) var statusQueries = 0
    private(set) var authorizationRequests: [UNAuthorizationOptions] = []
    private(set) var added: [UNNotificationRequest] = []

    init(status: UNAuthorizationStatus, answer: Bool = true) {
        self.status = status
        self.answer = answer
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        statusQueries += 1
        return status
    }

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        authorizationRequests.append(options)
        try await Task.sleep(for: .milliseconds(100))  // the prompt is on screen for a while
        status = answer ? .authorized : .denied
        return answer
    }

    func add(_ request: UNNotificationRequest) async throws {
        added.append(request)
    }
}

/// An app on a temporary data root whose mods notify at launch; nothing is started until `start()`.
@MainActor
private final class Fixture {
    let root = FileManager.default.temporaryDirectory.appending(path: "ToolsyNotify-\(UUID().uuidString)", directoryHint: .isDirectory)
    let center: FakeCenter
    let mods: ModsModel
    let notifier: ModNotifier
    private(set) var opened: [PanelPage?] = []

    /// `notifying` maps mod ids to the `notify` value (JSON) their launch command reports.
    init(center: FakeCenter, notifying: [String: String]) throws {
        self.center = center
        let directories = ToolsyDirectories(root: root)
        for (id, notify) in notifying {
            let folder = directories.mods.appending(path: id, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(#"{"done": true, "notify": \#(notify)}"#.utf8).write(to: folder.appending(path: "patch.json"))
            try Data(#"""
            {"schema": 1, "id": "\#(id)", "name": "Mod \#(id)", "version": "1",
             "commands": {"hello": {"shell": "cat patch.json"}}, "lifecycle": {"events": {"launch": "hello"}}}
            """#.utf8).write(to: folder.appending(path: "mod.json"))
        }
        mods = ModsModel(store: ModStore(directories: directories, privileged: SimulatedHelper(store: root.appending(path: "helper"))),
                         directories: directories, panel: PanelState(),
                         dashboard: DashboardStore(file: directories.root.appending(path: "Dashboard.json"), hasBattery: false))
        notifier = ModNotifier(center: center, mods: mods)
        notifier.openPanel = { [unowned self] page in opened.append(page) }
    }

    func start() async throws {
        mods.start()
        await mods.waitUntilStarted()
        try await waitUntil("the launch commands") { mods.store.mods.allSatisfy { $0.state["done"] == .bool(true) } }
    }

    func cleanUp() async {
        await mods.shutdown(within: .seconds(5))
        try? FileManager.default.removeItem(at: root)  // best effort: a temporary folder
    }

    func waitUntil(_ what: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("timed out waiting for \(what)")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

@MainActor
struct ModNotifierTests {
    @Test func permissionIsAskedOnceWhenAModFirstNotifiesAndEachModIsAGroup() async throws {
        let fixture = try Fixture(center: FakeCenter(status: .notDetermined), notifying: [
            "backup": #"{"title": "Backup finished", "body": "42 files, 1.2 GB"}"#,
            "vpn": #""Connected to Office VPN""#,
        ])
        #expect(fixture.center.statusQueries == 0 && fixture.center.authorizationRequests.isEmpty, "nothing is asked at launch")

        try await fixture.start()
        try await fixture.waitUntil("both notifications") { fixture.center.added.count == 2 }
        #expect(fixture.center.authorizationRequests == [[.alert]])

        let contents = fixture.center.added.map(\.content).sorted { $0.threadIdentifier < $1.threadIdentifier }
        #expect(contents.map(\.threadIdentifier) == ["backup", "vpn"])
        #expect(contents.map(\.title) == ["Backup finished", "Mod vpn"], "without a title, the mod's name")
        #expect(contents.map(\.body) == ["42 files, 1.2 GB", "Connected to Office VPN"])
        #expect(contents.allSatisfy { $0.sound == nil })
        #expect(Set(fixture.center.added.map(\.identifier)).count == 2, "one notification does not replace another")
        await fixture.cleanUp()
    }

    @Test func alreadyAllowedNotificationsAreShownWithoutAsking() async throws {
        let fixture = try Fixture(center: FakeCenter(status: .authorized), notifying: ["vpn": #""Connected""#])
        try await fixture.start()
        try await fixture.waitUntil("the notification") { fixture.center.added.count == 1 }
        #expect(fixture.center.authorizationRequests.isEmpty)
        await fixture.cleanUp()
    }

    @Test func refusedNotificationsAreDropped() async throws {
        let fixture = try Fixture(center: FakeCenter(status: .denied), notifying: ["a": #""one""#, "b": #""two""#])
        try await fixture.start()
        try await fixture.waitUntil("both notifications") { fixture.center.statusQueries == 2 }
        try await Task.sleep(for: .milliseconds(50))
        #expect(fixture.center.added.isEmpty)
        #expect(fixture.center.authorizationRequests.isEmpty, "a refusal is not asked again")
        await fixture.cleanUp()
    }

    @Test func aRefusalAtThePromptDropsTheNotification() async throws {
        let fixture = try Fixture(center: FakeCenter(status: .notDetermined, answer: false), notifying: ["a": #""one""#])
        try await fixture.start()
        try await fixture.waitUntil("the answer") { fixture.center.status == .denied }
        try await Task.sleep(for: .milliseconds(50))
        #expect(fixture.center.added.isEmpty)
        #expect(fixture.center.authorizationRequests.count == 1)
        await fixture.cleanUp()
    }

    @Test func aClickOpensTheModsPageWhileItIsInstalled() async throws {
        let fixture = try Fixture(center: FakeCenter(status: .authorized), notifying: ["vpn": #""Connected""#])
        // A click can be what launched Toolsy: it waits for the mods to load.
        fixture.mods.start()
        await fixture.notifier.open(modID: "vpn")
        await fixture.notifier.open(modID: "gone")
        #expect(fixture.opened == [.mod("vpn"), nil])
        await fixture.cleanUp()
    }
}
