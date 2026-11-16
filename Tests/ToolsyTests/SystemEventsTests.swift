import Foundation
import Observation
import Testing
import ToolsyEngine
import ToolsyShared
@testable import Toolsy

/// What the store would say `observedEvents` is.
@Observable
private final class Listening {
    var events: Set<ModSystemEvent> = []
}

/// A source the test drives: `report` is the system saying the condition may have changed.
private final class FakeSource: SystemEventSource {
    var condition: String?
    private(set) var isStarted = false
    private var changed: ((String?) -> Void)?

    init(condition: String?) {
        self.condition = condition
    }

    func start(_ changed: @escaping (String?) -> Void) -> String? {
        isStarted = true
        self.changed = changed
        return condition
    }

    func stop() {
        isStarted = false
        changed = nil
    }

    func report(_ condition: String?) {
        self.condition = condition
        changed?(condition)
    }
}

/// Makes fake sources the way the Mac would have them, and remembers each one.
private final class FakeMac {
    var conditions: [ModSystemEvent: String] = [.network: "en0 192.168.1.2", .power: "AC Power"]
    private(set) var made: [(event: ModSystemEvent, source: FakeSource)] = []

    func source(_ event: ModSystemEvent) -> FakeSource? {
        guard event != .launch else { return nil }
        let source = FakeSource(condition: conditions[event])
        made.append((event, source))
        return source
    }

    func latest(_ event: ModSystemEvent) -> FakeSource? {
        made.last { $0.event == event }?.source
    }
}

@MainActor
private func waitUntil(_ what: String, _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while !condition() {
        guard ContinuousClock.now < deadline else {
            Issue.record("timed out waiting for \(what)")
            throw CancellationError()
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}

@MainActor
struct SystemEventMonitorTests {
    private let listening = Listening()
    private let mac = FakeMac()
    private var posted: [ModSystemEvent] { recorder.posted }
    private let recorder = Recorder()

    private final class Recorder {
        var posted: [ModSystemEvent] = []
    }

    private func monitor(networkSettle: Duration = .milliseconds(100)) -> SystemEventMonitor {
        SystemEventMonitor(observing: { [listening] in listening.events }, post: { [recorder] in recorder.posted.append($0) },
                           networkSettle: networkSettle, makeSource: { [mac] in mac.source($0) })
    }

    @Test func observesOnlyWhatModsListenToAndFollowsChanges() async throws {
        let monitor = monitor()
        monitor.start()
        #expect(mac.made.isEmpty, "nobody listens: nothing is observed")

        listening.events = [.wake]
        try await waitUntil("the wake source") { monitor.sources.keys.sorted { $0.rawValue < $1.rawValue } == [.wake] }
        let wake = try #require(mac.latest(.wake))
        #expect(wake.isStarted)
        wake.report(nil)
        wake.report(nil)
        #expect(posted == [.wake, .wake], "every wake is an event")

        // `launch` has no source: the store posts it itself.
        listening.events = [.wake, .power, .launch]
        try await waitUntil("the power source") { monitor.sources[.power] != nil }
        #expect(Set(monitor.sources.keys) == [.wake, .power])
        #expect(mac.made.count == 2, "the wake source is kept, not made again")

        listening.events = [.power]
        try await waitUntil("the wake source to stop") { monitor.sources[.wake] == nil }
        #expect(!wake.isStarted)
        wake.report(nil)
        #expect(posted == [.wake, .wake])

        monitor.stop()
        let power = try #require(mac.latest(.power))
        #expect(!power.isStarted)
        #expect(monitor.sources.isEmpty)
        listening.events = [.wake, .network, .power]
        try await Task.sleep(for: .milliseconds(100))
        #expect(mac.made.count == 2, "a stopped monitor follows nothing")
    }

    @Test func aBurstOfNetworkChangesIsOneEvent() async throws {
        listening.events = [.network]
        // Callbacks 20 ms apart, as configd sends them; the window leaves room for a busy test run.
        let monitor = monitor(networkSettle: .milliseconds(500))
        monitor.start()
        let network = try #require(mac.latest(.network))
        for address in ["", "en0 10.0.0.7", "en0 10.0.0.7\nutun3 10.8.0.2"] {
            network.report(address)
            try await Task.sleep(for: .milliseconds(20))
        }
        try await waitUntil("the event") { !posted.isEmpty }
        try await Task.sleep(for: .milliseconds(700))
        #expect(posted == [.network])

        // Callbacks that end where the network was are no change.
        network.report("")
        network.report("en0 10.0.0.7\nutun3 10.8.0.2")
        try await Task.sleep(for: .milliseconds(700))
        #expect(posted == [.network])

        network.report("en0 10.0.0.7")
        try await waitUntil("the second event") { posted.count == 2 }

        // Stopping drops a burst still settling.
        network.report("en1 192.168.5.20")
        monitor.stop()
        try await Task.sleep(for: .milliseconds(700))
        #expect(posted == [.network, .network])
    }

    @Test func powerIsAnEventOnlyWhenTheSourceChanges() async throws {
        listening.events = [.power]
        let monitor = monitor()
        monitor.start()
        let power = try #require(mac.latest(.power))
        power.report("AC Power")
        #expect(posted.isEmpty, "a callback without a change, as for the charge")
        power.report("Battery Power")
        power.report("Battery Power")
        #expect(posted == [.power])
        power.report("AC Power")
        #expect(posted == [.power, .power])
        monitor.stop()
    }

    @Test func aSourceUnreadableAtStartTakesItsFirstReportAsTheBaseline() async throws {
        mac.conditions[.power] = nil
        listening.events = [.power]
        let monitor = monitor()
        monitor.start()
        let power = try #require(mac.latest(.power))
        power.report("Battery Power")
        #expect(posted.isEmpty)
        power.report("AC Power")
        #expect(posted == [.power])
        monitor.stop()
    }
}

/// The monitor on a real store: what mods declare decides what is observed, and an event runs their command.
@MainActor
struct SystemEventsOnTheStoreTests {
    @Test func anIdleAppObservesNothingAndAModsEventRunsItsCommand() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "ToolsyEvents-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }  // best effort: a temporary folder
        let directories = ToolsyDirectories(root: root)
        let store = ModStore(directories: directories, privileged: SimulatedHelper(store: root.appending(path: "helper")))
        let mac = FakeMac()
        var asked: [ModSystemEvent] = []
        let monitor = SystemEventMonitor(observing: { store.observedEvents }, post: { store.post($0) },
                                         makeSource: { asked.append($0); return mac.source($0) })
        monitor.start()
        await store.start()
        try await Task.sleep(for: .milliseconds(100))
        #expect(asked.isEmpty, "no mods: no source is even made")
        #expect(monitor.sources.isEmpty)

        let folder = directories.mods.appending(path: "sync", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"""
        {"schema": 1, "id": "sync", "name": "Sync", "version": "1",
         "commands": {"sync": {"shell": "printf '{\"last\": \"%s\"}' \"$TOOLSY_EVENT\""}},
         "lifecycle": {"events": {"wake": "sync"}}}
        """#.utf8).write(to: folder.appending(path: "mod.json"))
        let mod = try await store.reload("sync")
        try await waitUntil("the wake source") { monitor.sources[.wake] != nil }
        #expect(asked == [.wake])

        try #require(mac.latest(.wake)).report(nil)
        try await waitUntil("the event command") { mod.state["last"] == .string("wake") }

        try await store.uninstall(mod)
        try await waitUntil("the wake source to stop") { monitor.sources.isEmpty }
        #expect(mac.latest(.wake)?.isStarted == false)
        monitor.stop()
        await store.shutdown()
    }
}

// MARK: - The Mac's own sources

@MainActor
struct SystemSourcesOnThisMacTests {
    @Test func theSourcesStartWithTheirConditionAndStop() async throws {
        #expect(SystemEventMonitor.systemSource(for: .launch) == nil)

        let wake = try #require(SystemEventMonitor.systemSource(for: .wake))
        #expect(wake.start { _ in } == nil, "waking is an occurrence")
        wake.stop()

        let power = try #require(SystemEventMonitor.systemSource(for: .power))
        let source = power.start { _ in }
        #expect(["AC Power", "Battery Power", "UPS Power"].contains(source ?? ""))
        power.stop()

        let network = try #require(SystemEventMonitor.systemSource(for: .network))
        let condition = try #require(network.start { _ in }, "readable, if empty without a network")
        #expect(!condition.contains("fe80:"), "link-local addresses do not count")
        #expect(condition.split(separator: "\n").allSatisfy { $0.hasPrefix("State:/Network/") })
        network.stop()
        // The dynamic store is released on a queue of its own, and with it the source.
        try await Task.sleep(for: .milliseconds(300))
    }
}
