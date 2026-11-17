import Foundation
import Testing
@testable import Toolsy

private let gigabyte: Int64 = 1_000_000_000

struct AlertLevelTests {
    @Test func memoryPressureAlarmsAboveNormal() {
        #expect(AlertCondition.memoryPressure(.normal).level == .clear)
        #expect(AlertCondition.memoryPressure(.warning).level == .alarming)
        #expect(AlertCondition.memoryPressure(.critical).level == .alarming)
    }

    @Test func heatAlarmsWhenSeriousAndClearsOnlyOnceCool() {
        #expect(AlertCondition.thermal(.serious).level == .alarming)
        #expect(AlertCondition.thermal(.critical).level == .alarming)
        // Fair is warm, or cooling down: a Mac going between fair and serious is one episode.
        #expect(AlertCondition.thermal(.fair).level == .between)
        #expect(AlertCondition.thermal(.nominal).level == .clear)
    }

    @Test func batteryAlarmsAtTwentyPercentOnBatteryAndClearsAtTwentyFive() {
        #expect(AlertCondition.battery(percent: 20, onBattery: true).level == .alarming)
        #expect(AlertCondition.battery(percent: 3, onBattery: true).level == .alarming)
        #expect(AlertCondition.battery(percent: 21, onBattery: true).level == .between)
        #expect(AlertCondition.battery(percent: 24, onBattery: true).level == .between)
        #expect(AlertCondition.battery(percent: 25, onBattery: true).level == .clear)
        // Charging is no reason to alert, nor does plugging in end a low battery by itself.
        #expect(AlertCondition.battery(percent: 15, onBattery: false).level == .between)
        #expect(AlertCondition.battery(percent: 80, onBattery: false).level == .clear)
    }

    @Test func diskSpaceAlarmsBelowTenGigabytesAndClearsAtFifteen() {
        #expect(AlertCondition.freeSpace(10 * gigabyte - 1).level == .alarming)
        #expect(AlertCondition.freeSpace(0).level == .alarming)
        #expect(AlertCondition.freeSpace(10 * gigabyte).level == .between)
        #expect(AlertCondition.freeSpace(15 * gigabyte - 1).level == .between)
        #expect(AlertCondition.freeSpace(15 * gigabyte).level == .clear)
    }

    @Test func notificationsSayWhatHappened() {
        #expect(AlertCondition.battery(percent: 18, onBattery: true).notification.body.contains("18"))
        #expect(AlertCondition.freeSpace(8_200_000_000).notification.body.contains(Format.storage(8_200_000_000)))
        for condition in [AlertCondition.memoryPressure(.warning), .thermal(.serious)] {
            #expect(!condition.notification.title.isEmpty && !condition.notification.body.isEmpty)
        }
    }

    @Test func labelsSayTheThreshold() {
        #expect(AlertsSection.label(for: .lowBattery).contains("20"))
        #expect(AlertsSection.label(for: .lowDiskSpace).contains(Format.storage(10 * gigabyte)))
    }
}

struct AlertEpisodeTests {
    private func notifications(_ levels: [AlertLevel]) -> [Bool] {
        var episode = AlertEpisode()
        return levels.map { episode.notifies(at: $0) }
    }

    @Test func oneNotificationPerEpisode() {
        #expect(notifications([.clear, .alarming, .alarming, .alarming]) == [false, true, false, false])
        // Within the margin the episode goes on; past it, the next one notifies again.
        #expect(notifications([.alarming, .between, .alarming, .clear, .alarming]) == [true, false, false, false, true])
    }

    @Test func aConditionThatHoldsWhenWatchingStartsNotifies() {
        #expect(notifications([.alarming]) == [true])
        #expect(notifications([.between, .alarming]) == [false, true])
    }
}

// MARK: - Alerts

/// A source the test drives: `report` is the Mac telling a new reading.
private final class FakeAlertSource: AlertSource {
    private(set) var isStarted = false
    private var changed: ((AlertCondition) -> Void)?
    private let initial: AlertCondition?

    init(initial: AlertCondition?) {
        self.initial = initial
    }

    func start(_ changed: @escaping (AlertCondition) -> Void) {
        isStarted = true
        self.changed = changed
        if let initial { changed(initial) }
    }

    func stop() {
        isStarted = false
        changed = nil
    }

    func report(_ condition: AlertCondition) {
        changed?(condition)
    }
}

/// What the alerts did, and the answers they get. Their closures hold this, so a permission question still on its
/// way when a test ends finds it.
@MainActor
private final class AlertsRecorder {
    var isReclaiming = false
    var refused = false
    var posted: [(alert: MacAlert, title: String)] = []
    var permissionQueries: [Bool] = []
    var made: [MacAlert: FakeAlertSource] = [:]
    /// What each new source reports as it starts.
    var initial: [MacAlert: AlertCondition] = [:]
}

/// Alerts on a temporary settings file, with fake sources.
@MainActor
private final class AlertsFixture {
    let file = FileManager.default.temporaryDirectory.appending(path: "ToolsyAlerts-\(UUID().uuidString)/Settings.json")
    let settings: AppSettings
    let recorder = AlertsRecorder()
    let alerts: SystemAlerts

    init(hasBattery: Bool = true) {
        settings = AppSettings(file: file)
        alerts = SystemAlerts(
            settings: settings, hasBattery: hasBattery,
            isReclaimingMemory: { [recorder] in recorder.isReclaiming },
            post: { [recorder] alert, title, _ in recorder.posted.append((alert, title)) },
            isRefused: { [recorder] askingFirst in
                recorder.permissionQueries.append(askingFirst)
                return recorder.refused
            },
            makeSource: { [recorder] alert in
                let source = FakeAlertSource(initial: recorder.initial[alert])
                recorder.made[alert] = source
                return source
            }
        )
    }

    var made: [MacAlert: FakeAlertSource] { recorder.made }
    var posted: [(alert: MacAlert, title: String)] { recorder.posted }
    var postedAlerts: [MacAlert] { recorder.posted.map(\.alert) }

    func cleanUp() {
        alerts.stop()
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())  // best effort: a temporary folder
    }
}

@MainActor
struct SystemAlertsTests {
    @Test func withEveryAlertOffNothingIsWatched() {
        let fixture = AlertsFixture()
        fixture.alerts.start()
        #expect(fixture.alerts.sources.isEmpty && fixture.made.isEmpty)
        #expect(MacAlert.allCases.allSatisfy { !fixture.alerts.isOn($0) }, "every alert is off by default")
        fixture.cleanUp()
    }

    @Test func onlyTheAlertsSwitchedOnAreWatched() {
        let fixture = AlertsFixture()
        fixture.alerts.start()
        fixture.alerts.set(.heat, on: true)
        fixture.alerts.set(.lowDiskSpace, on: true)
        #expect(Set(fixture.alerts.sources.keys) == [.heat, .lowDiskSpace])
        let heat = fixture.made[.heat]
        #expect(heat?.isStarted == true)

        fixture.alerts.set(.heat, on: false)
        #expect(Set(fixture.alerts.sources.keys) == [.lowDiskSpace])
        #expect(heat?.isStarted == false, "a switched-off alert's source is released")
        fixture.alerts.stop()
        #expect(fixture.alerts.sources.isEmpty)
        #expect(fixture.made[.lowDiskSpace]?.isStarted == false)
        fixture.cleanUp()
    }

    @Test func switchesAreSavedAndWatchedFromTheNextLaunch() {
        let fixture = AlertsFixture()
        fixture.alerts.set(.memoryPressure, on: true)
        #expect(fixture.alerts.sources.isEmpty, "nothing is watched before the app starts them")
        let relaunched = AppSettings(file: fixture.file)
        #expect(relaunched.alerts == [.memoryPressure])
        fixture.cleanUp()
    }

    @Test func aMacWithoutABatteryHasNoBatteryAlert() {
        let fixture = AlertsFixture(hasBattery: false)
        #expect(!fixture.alerts.available.contains(.lowBattery))
        // Saved on another Mac, or before the battery was gone: still nothing to watch.
        fixture.settings.alerts = [.lowBattery]
        fixture.alerts.start()
        #expect(fixture.alerts.sources.isEmpty)
        fixture.cleanUp()
    }

    @Test func anAlertNotifiesOncePerEpisode() {
        let fixture = AlertsFixture()
        fixture.recorder.initial[.lowBattery] = .battery(percent: 40, onBattery: true)
        fixture.alerts.start()
        fixture.alerts.set(.lowBattery, on: true)
        let battery = try! #require(fixture.made[.lowBattery])
        for percent in [30, 20, 19, 21, 20, 18] {
            battery.report(.battery(percent: percent, onBattery: true))
        }
        #expect(fixture.posted.map(\.title) == [AlertCondition.battery(percent: 20, onBattery: true).notification.title])
        // Charged past the margin, then low again: a new episode.
        battery.report(.battery(percent: 60, onBattery: false))
        battery.report(.battery(percent: 20, onBattery: true))
        #expect(fixture.postedAlerts == [.lowBattery, .lowBattery])
        fixture.cleanUp()
    }

    @Test func aConditionThatAlreadyHoldsNotifiesWhenSwitchedOn() {
        let fixture = AlertsFixture()
        fixture.recorder.initial[.lowDiskSpace] = .freeSpace(3 * gigabyte)
        fixture.alerts.start()
        fixture.alerts.set(.lowDiskSpace, on: true)
        #expect(fixture.postedAlerts == [.lowDiskSpace])
        // Switched off and on again: watching starts over.
        fixture.alerts.set(.lowDiskSpace, on: false)
        fixture.alerts.set(.lowDiskSpace, on: true)
        #expect(fixture.postedAlerts == [.lowDiskSpace, .lowDiskSpace])
        fixture.cleanUp()
    }

    @Test func pressureFromToolsysOwnReclaimIsNoAlert() {
        let fixture = AlertsFixture()
        fixture.recorder.initial[.memoryPressure] = .memoryPressure(.normal)
        fixture.alerts.start()
        fixture.alerts.set(.memoryPressure, on: true)
        let pressure = try! #require(fixture.made[.memoryPressure])
        // Free Up Memory holds the warning level for a few seconds.
        fixture.recorder.isReclaiming = true
        pressure.report(.memoryPressure(.warning))
        pressure.report(.memoryPressure(.normal))
        fixture.recorder.isReclaiming = false
        #expect(fixture.posted.isEmpty)
        pressure.report(.memoryPressure(.warning))
        pressure.report(.memoryPressure(.critical))
        #expect(fixture.postedAlerts == [.memoryPressure])
        fixture.cleanUp()
    }

    @Test func switchingAnAlertOnAsksForPermissionAndSettingsOnlyLooks() async throws {
        let fixture = AlertsFixture()
        fixture.recorder.refused = true
        await fixture.alerts.refreshPermission()
        #expect(fixture.recorder.permissionQueries == [false])
        #expect(fixture.alerts.notificationsRefused)

        fixture.recorder.refused = false
        fixture.alerts.set(.heat, on: true)
        let deadline = ContinuousClock.now + .seconds(5)
        while fixture.alerts.notificationsRefused, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(fixture.recorder.permissionQueries == [false, true])
        #expect(!fixture.alerts.notificationsRefused)
        fixture.alerts.set(.heat, on: false)
        #expect(fixture.recorder.permissionQueries.count == 2, "switching off asks nothing")
        fixture.cleanUp()
    }
}

// MARK: - The Mac's sources

@MainActor
struct MacAlertSourceTests {
    /// Each source reads the Mac once as it starts, and stopping it ends its reports. Only reads: nothing is
    /// changed and nothing is posted.
    @Test func sourcesReadTheMacAsTheyStart() async throws {
        var readings: [AlertCondition] = []
        let memory = MemoryPressureSource(), heat = ThermalSource(), disk = FreeSpaceSource()
        memory.start { readings.append($0) }
        heat.start { readings.append($0) }
        disk.start { readings.append($0) }
        let deadline = ContinuousClock.now + .seconds(10)
        while !readings.contains(where: { if case .freeSpace = $0 { true } else { false } }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        memory.stop()
        heat.stop()
        disk.stop()
        #expect(readings.contains { if case .memoryPressure = $0 { true } else { false } })
        #expect(readings.contains(.thermal(ProcessInfo.processInfo.thermalState)))
        let free = readings.compactMap { if case .freeSpace(let bytes) = $0 { bytes } else { nil } }
        #expect(free.count == 1 && free[0] > 0)

        if BatteryReader.isPresent {
            var battery: [AlertCondition] = []
            let source = BatterySource()
            source.start { battery.append($0) }
            source.stop()
            #expect(battery.count == 1)
        }
    }
}

// MARK: - Settings file

@MainActor
struct AppSettingsTests {
    private func folder() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "ToolsySettings-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    @Test func savedOnEveryChangeAndLoadedAgain() throws {
        let folder = folder()
        defer { try? FileManager.default.removeItem(at: folder) }  // best effort: a temporary folder
        let file = folder.appending(path: "Settings.json")
        let settings = AppSettings(file: file)
        #expect(settings.alerts.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.path(percentEncoded: false)), "nothing is written until something changes")
        settings.alerts = [.heat, .memoryPressure]
        #expect(AppSettings(file: file).alerts == [.heat, .memoryPressure])
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        #expect(json["version"] as? Int == 1)
        #expect(json["alerts"] as? [String] == ["heat", "memoryPressure"])
        settings.dismissedUpdate = "1.3.0"
        settings.lastRunVersion = "1.2.0"
        let reloaded = AppSettings(file: file)
        #expect(reloaded.dismissedUpdate == "1.3.0")
        #expect(reloaded.lastRunVersion == "1.2.0")
        #expect(reloaded.alerts == [.heat, .memoryPressure])
    }

    @Test func aFileThatCannotBeUsedGivesTheDefaultsAndIsLeftAlone() throws {
        let folder = folder()
        defer { try? FileManager.default.removeItem(at: folder) }  // best effort: a temporary folder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "Settings.json")
        for content in [#"{"version": 2, "alerts": ["heat"]}"#, "not json", #"{"alerts": ["heat"]}"#] {
            try Data(content.utf8).write(to: file)
            let settings = AppSettings(file: file)
            #expect(settings.alerts.isEmpty, "\(content)")
            // What Toolsy notes by itself does not replace it either; only a change the user makes does.
            settings.lastRunVersion = "1.2.0"
            #expect(try String(contentsOf: file, encoding: .utf8) == content)
        }
        // An alert this version does not know is skipped; the others load.
        try Data(#"{"version": 1, "alerts": ["heat", "solarFlare"]}"#.utf8).write(to: file)
        #expect(AppSettings(file: file).alerts == [.heat])
    }
}
