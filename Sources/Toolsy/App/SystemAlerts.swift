import AppKit
import IOKit.ps
import os
import ToolsyShared

private let logger = Logger(subsystem: ToolsyPaths.bundleIdentifier, category: "alerts")

/// An alert about the Mac that the user can switch on in Settings.
enum MacAlert: String, CaseIterable {
    case memoryPressure, heat, lowBattery, lowDiskSpace

    /// The battery is low at this charge or less, while the Mac runs on it.
    static let lowBatteryPercent = 20
    /// The charge must be back at this before the battery alert can notify again: it wavers by a percent or two.
    static let rechargedPercent = 25
    /// Less free space than this on the startup disk is low, counted as Finder does (decimal units).
    static let lowFreeSpace: Int64 = 10_000_000_000
    /// Free space must be back at this before the disk alert can notify again: caches and swap come and go.
    static let recoveredFreeSpace: Int64 = 15_000_000_000
}

/// A reading of what an alert watches.
enum AlertCondition: Equatable {
    case memoryPressure(MemoryPressure)
    case thermal(ProcessInfo.ThermalState)
    case battery(percent: Int, onBattery: Bool)
    /// Free space on the startup disk, in bytes.
    case freeSpace(Int64)

    /// Where the reading stands. Between the threshold and the point where the condition counts as cleared
    /// lies a margin, so that a value hovering around the threshold does not start one episode after another.
    var level: AlertLevel {
        switch self {
        case .memoryPressure(let pressure):
            pressure == .normal ? .clear : .alarming
        case .thermal(let state):
            switch state {
            case .serious, .critical: .alarming
            case .nominal: .clear
            // Fair: warm, or cooling down from hot.
            default: .between
            }
        case .battery(let percent, let onBattery):
            onBattery && percent <= MacAlert.lowBatteryPercent ? .alarming
                : percent >= MacAlert.rechargedPercent ? .clear : .between
        case .freeSpace(let bytes):
            bytes < MacAlert.lowFreeSpace ? .alarming : bytes >= MacAlert.recoveredFreeSpace ? .clear : .between
        }
    }

    /// What the notification says when this reading starts an episode.
    var notification: (title: String, body: String) {
        switch self {
        case .memoryPressure:
            (String(localized: "Memory pressure is high"),
             String(localized: "Apps may slow down. Toolsy’s Memory details show which apps use the most."))
        case .thermal:
            (String(localized: "The Mac is hot"),
             String(localized: "macOS slows it down to cool it. Toolsy’s CPU details show which apps work the hardest."))
        case .battery(let percent, _):
            (String(localized: "Battery is low"),
             String(localized: "\(Format.percent(Double(percent) / 100)) left. Connect the power adapter."))
        case .freeSpace(let bytes):
            (String(localized: "Startup disk is almost full"),
             String(localized: "\(Format.storage(bytes)) free. Apps may fail to save their work."))
        }
    }
}

/// Where a reading stands for its alert.
enum AlertLevel: Equatable {
    /// The condition holds.
    case alarming
    /// Neither holds nor has cleared: within the margin past the threshold.
    case between
    /// The condition has cleared.
    case clear
}

/// One notification per episode: an alert notifies when its condition starts, and again only once the condition
/// has cleared. A reading of a condition that already holds when the alert starts watching starts an episode.
struct AlertEpisode: Equatable {
    private(set) var isArmed = true

    /// Takes the level of a new reading and says whether it notifies.
    mutating func notifies(at level: AlertLevel) -> Bool {
        switch level {
        case .alarming:
            defer { isArmed = false }
            return isArmed
        case .clear:
            isArmed = true
            return false
        case .between:
            return false
        }
    }
}

/// Where the Mac reports what one alert watches.
protocol AlertSource: AnyObject {
    /// Starts watching. `changed` runs on the main actor with every reading: the one now, when it can be read, and
    /// each one the Mac reports later.
    func start(_ changed: @escaping (AlertCondition) -> Void)
    /// Releases everything `start` created; `changed` is not called afterwards.
    func stop()
}

/// The alerts about the Mac: high memory pressure, heat, a low battery, a nearly full startup disk. Each one is off
/// until switched on in Settings, and an alert that is off costs nothing: its source is created when it is
/// switched on and released when it is switched off. Each notifies once per episode (`AlertEpisode`).
@Observable
final class SystemAlerts {
    /// The alerts this Mac offers: the battery's only on a Mac with one.
    let available: [MacAlert]
    /// Toolsy may not show notifications, so an alert would go unseen. Known once asked (`refreshPermission`, or
    /// switching an alert on).
    private(set) var notificationsRefused = false

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let isReclaimingMemory: () -> Bool
    @ObservationIgnored private let post: (_ alert: MacAlert, _ title: String, _ body: String) -> Void
    @ObservationIgnored private let isRefused: (_ askingFirst: Bool) async -> Bool
    @ObservationIgnored private let makeSource: @MainActor (MacAlert) -> any AlertSource
    @ObservationIgnored private var isRunning = false
    @ObservationIgnored private(set) var sources: [MacAlert: any AlertSource] = [:]
    @ObservationIgnored private var episodes: [MacAlert: AlertEpisode] = [:]

    /// `isReclaimingMemory` is true while Toolsy itself holds the memory pressure up (`MemoryOptimizer`), which is
    /// no reason to alert. `isRefused` says whether notifications are refused, with `askingFirst` asking the user
    /// if they never answered.
    init(settings: AppSettings, hasBattery: Bool,
         isReclaimingMemory: @escaping () -> Bool,
         post: @escaping (_ alert: MacAlert, _ title: String, _ body: String) -> Void,
         isRefused: @escaping (_ askingFirst: Bool) async -> Bool,
         makeSource: @escaping @MainActor (MacAlert) -> any AlertSource = SystemAlerts.systemSource) {
        self.settings = settings
        available = MacAlert.allCases.filter { $0 != .lowBattery || hasBattery }
        self.isReclaimingMemory = isReclaimingMemory
        self.post = post
        self.isRefused = isRefused
        self.makeSource = makeSource
    }

    func isOn(_ alert: MacAlert) -> Bool {
        settings.alerts.contains(alert)
    }

    /// Switching an alert on asks for permission to notify if the user never answered.
    func set(_ alert: MacAlert, on: Bool) {
        if on {
            settings.alerts.insert(alert)
            Task { notificationsRefused = await isRefused(true) }
        } else {
            settings.alerts.remove(alert)
        }
        follow()
    }

    /// Whether notifications are refused now; never asks.
    func refreshPermission() async {
        notificationsRefused = await isRefused(false)
    }

    func start() {
        isRunning = true
        follow()
    }

    func stop() {
        isRunning = false
        follow()
    }

    /// Watches what the switches ask for, and nothing else.
    private func follow() {
        let wanted = isRunning ? Set(available).intersection(settings.alerts) : []
        for (alert, source) in sources where !wanted.contains(alert) {
            source.stop()
            sources[alert] = nil
            episodes[alert] = nil
        }
        for alert in available where wanted.contains(alert) && sources[alert] == nil {
            let source = makeSource(alert)
            sources[alert] = source
            episodes[alert] = AlertEpisode()
            source.start { [weak self] condition in self?.report(condition, of: alert) }
        }
    }

    private func report(_ condition: AlertCondition, of alert: MacAlert) {
        // Pressure that Toolsy's own reclaim causes neither starts nor ends an episode.
        let level = alert == .memoryPressure && isReclaimingMemory() ? .between : condition.level
        guard episodes[alert]?.notifies(at: level) == true else { return }
        let notification = condition.notification
        post(alert, notification.title, notification.body)
    }

    /// The Mac's own source for `alert`.
    static func systemSource(for alert: MacAlert) -> any AlertSource {
        switch alert {
        case .memoryPressure: MemoryPressureSource()
        case .heat: ThermalSource()
        case .lowBattery: BatterySource()
        case .lowDiskSpace: FreeSpaceSource()
        }
    }
}

// MARK: - The Mac's sources

/// The kernel's memory pressure events, for every change of level, back to normal included.
final class MemoryPressureSource: AlertSource {
    private var source: (any DispatchSourceMemoryPressure)?
    private var changed: ((AlertCondition) -> Void)?

    func start(_ changed: @escaping (AlertCondition) -> Void) {
        self.changed = changed
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.report() }
        }
        source.resume()
        self.source = source
        // The source tells changes only.
        changed(.memoryPressure(.read()))
    }

    private func report() {
        guard let event = source?.data else { return }
        let pressure: MemoryPressure = event.contains(.critical) ? .critical : event.contains(.warning) ? .warning : .normal
        changed?(.memoryPressure(pressure))
    }

    func stop() {
        source?.cancel()
        source = nil
        changed = nil
    }
}

/// `ProcessInfo.thermalStateDidChangeNotification`, posted when macOS changes how much it throttles the Mac to cool it.
final class ThermalSource: AlertSource {
    private var observer: (any NSObjectProtocol)?
    private var changed: ((AlertCondition) -> Void)?

    func start(_ changed: @escaping (AlertCondition) -> Void) {
        self.changed = changed
        observer = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.report() }
        }
        report()
    }

    private func report() {
        changed?(.thermal(ProcessInfo.processInfo.thermalState))
    }

    func stop() {
        observer.map(NotificationCenter.default.removeObserver)
        observer = nil
        changed = nil
    }
}

/// `IOPSNotificationCreateRunLoopSource`, which fires when a power source changes: its charge, or the Mac moving
/// between the adapter and the battery.
final class BatterySource: AlertSource {
    private let reader = BatteryReader()
    private var runLoopSource: CFRunLoopSource?
    private var changed: ((AlertCondition) -> Void)?

    func start(_ changed: @escaping (AlertCondition) -> Void) {
        self.changed = changed
        // Unretained: the run loop source is invalidated in `stop`, and run loop callbacks are synchronous on the
        // main thread, so none can arrive after it.
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            let source = Unmanaged<BatterySource>.fromOpaque(context!).takeUnretainedValue()  // the context passed below
            MainActor.assumeIsolated { source.report() }
        }, Unmanaged.passUnretained(self).toOpaque())?.takeRetainedValue() else {
            logger.error("cannot observe the battery")
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        runLoopSource = source
        report()
    }

    private func report() {
        guard let battery = reader.read() else { return }
        changed?(.battery(percent: battery.percent, onBattery: !battery.isOnAC))
    }

    func stop() {
        if let runLoopSource { CFRunLoopSourceInvalidate(runLoopSource) }
        runLoopSource = nil
        changed = nil
    }
}

/// Free space on the startup disk. Nothing reports it as it changes, so it is read when watching starts (at launch,
/// or when the alert is switched on), when the Mac wakes, and about every 30 minutes as the system finds a moment.
final class FreeSpaceSource: AlertSource {
    private var scheduler: NSBackgroundActivityScheduler?
    private var wakeObserver: (any NSObjectProtocol)?
    private var changed: ((AlertCondition) -> Void)?
    private var isFailureReported = false

    func start(_ changed: @escaping (AlertCondition) -> Void) {
        self.changed = changed
        let scheduler = NSBackgroundActivityScheduler(identifier: "\(ToolsyPaths.bundleIdentifier).free-space-alert")
        scheduler.repeats = true
        scheduler.interval = 30 * 60
        scheduler.schedule { [weak self] completion in
            // On a queue of the scheduler's, where the disk can take its time.
            let reading = Result { try StorageReading.readStartupVolume().available }
            Task { @MainActor in self?.report(reading) }
            completion(.finished)
        }
        self.scheduler = scheduler
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.read() }
        }
        read()
    }

    /// Computing purgeable space can take a moment: off the main thread.
    private func read() {
        Task.detached(priority: .utility) { [weak self] in
            let reading = Result { try StorageReading.readStartupVolume().available }
            await self?.report(reading)
        }
    }

    private func report(_ reading: Result<Int64, any Error>) {
        guard changed != nil else { return }  // stopped meanwhile
        switch reading {
        case .success(let bytes):
            isFailureReported = false
            changed?(.freeSpace(bytes))
        case .failure(let error):
            guard !isFailureReported else { return }
            isFailureReported = true
            logger.error("cannot read the free space of the startup disk: \(error.localizedDescription, privacy: .public)")
        }
    }

    func stop() {
        scheduler?.invalidate()
        scheduler = nil
        wakeObserver.map(NSWorkspace.shared.notificationCenter.removeObserver)
        wakeObserver = nil
        changed = nil
    }
}
