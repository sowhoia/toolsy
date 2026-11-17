import Foundation
import Observation

/// A reading of the Mac the dashboard can show. Each is the subject of one built-in widget.
enum SystemMetric: String, CaseIterable, Sendable {
    case cpu, memory, battery, network, storage, gpu, disk
}

/// Samples the Mac about once a second while the panel is visible and not at all otherwise, and
/// only the metrics something on the dashboard shows (`shownMetrics`).
///
/// Readings are kept when sampling stops, so reopening the panel shows the last values at once
/// instead of zeros; each start takes a fresh baseline for the rate-based readings (CPU,
/// network, disk) and replaces the stale values a quarter of a second later. The charts' histories
/// are not kept: samples from an earlier opening would read as if they ran on into the new ones.
@Observable
final class SystemMonitor {
    let device = DeviceInfo.current()
    /// What this Mac can measure: no battery on a desktop Mac, no GPU or disk activity where the
    /// drivers do not report them. The dashboard offers only these.
    let availableMetrics: Set<SystemMetric>
    /// The GPU's name, such as "Apple M4".
    let gpuModel: String?
    private(set) var uptime: TimeInterval?
    private(set) var cpu: CPULoad?
    private(set) var cpuHistory = SampleHistory(capacity: 60)
    private(set) var memory: MemoryReading?
    /// Nil on a Mac without a battery.
    private(set) var battery: BatteryReading?
    private(set) var storage: StorageReading?
    private(set) var downloadRate: Double?
    private(set) var uploadRate: Double?
    private(set) var downloadHistory = SampleHistory(capacity: 60)
    private(set) var uploadHistory = SampleHistory(capacity: 60)
    private(set) var interface: NetworkInterface?
    private(set) var thermalState = ProcessInfo.processInfo.thermalState
    private(set) var gpu: GPUReading?
    private(set) var gpuHistory = SampleHistory(capacity: 60)
    private(set) var disk: DiskActivity?
    private(set) var diskReadHistory = SampleHistory(capacity: 60)
    private(set) var diskWriteHistory = SampleHistory(capacity: 60)

    @ObservationIgnored private let cpuSampler = CPUSampler()
    @ObservationIgnored private let networkSampler = NetworkSampler()
    @ObservationIgnored private let diskSampler = DiskActivitySampler()
    @ObservationIgnored private let batteryReader: BatteryReader?
    @ObservationIgnored private let gpuReader: GPUReader?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var ticks = 0
    @ObservationIgnored private var storageTask: Task<Void, Never>?

    /// The primary interface's name and address are read when sampling starts, and kept up to
    /// date only while something shows them (they cost a configd round trip).
    @ObservationIgnored var wantsInterfaceUpdates = false {
        didSet {
            if wantsInterfaceUpdates, !oldValue, isRunning { interface = networkSampler.primaryInterface() }
        }
    }

    /// The metrics a widget on the dashboard shows; nothing else is sampled. One that is added while
    /// sampling runs is read (or, for a rate, gets its baseline) at once.
    @ObservationIgnored var shownMetrics: Set<SystemMetric> = [] {
        didSet {
            guard isRunning else { return }
            for metric in shownMetrics.subtracting(oldValue) { begin(metric) }
        }
    }

    init(simulateNoBattery: Bool = false) {
        batteryReader = simulateNoBattery || !BatteryReader.isPresent ? nil : BatteryReader()
        gpuReader = GPUReader()
        gpuModel = gpuReader?.model
        var available = Set(SystemMetric.allCases)
        if batteryReader == nil { available.remove(.battery) }
        if gpuReader == nil { available.remove(.gpu) }
        if DiskActivitySampler.readCounters().isEmpty { available.remove(.disk) }
        availableMetrics = available
    }

    var isRunning: Bool { timer != nil }

    func start() {
        guard timer == nil else { return }
        for metric in shownMetrics { begin(metric) }
        thermalState = ProcessInfo.processInfo.thermalState
        updateUptime()
        ticks = 0
        // The first real sample comes quickly so the stale values do not linger; after that
        // once a second. The tolerance lets the system coalesce the wake-ups.
        schedule(after: 0.25)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        storageTask?.cancel()
        storageTask = nil
    }

    private func schedule(after interval: TimeInterval) {
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = interval * 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        guard timer != nil else { return }
        ticks += 1
        let shown = shownMetrics
        if shown.contains(.cpu), let load = cpuSampler.sample() {
            cpu = load
            cpuHistory.append(load.total * 100)
        }
        if shown.contains(.network), let rates = networkSampler.sample() {
            downloadRate = rates.download
            uploadRate = rates.upload
            downloadHistory.append(rates.download)
            uploadHistory.append(rates.upload)
        }
        if shown.contains(.gpu), let reading = gpuReader?.read() {
            gpu = reading
            gpuHistory.append(reading.utilization * 100)
        }
        if shown.contains(.disk), let activity = diskSampler.sample() {
            disk = activity
            diskReadHistory.append(activity.readRate)
            diskWriteHistory.append(activity.writeRate)
        }
        if shown.contains(.memory) { memory = MemoryReading.read() }
        updateUptime()
        thermalState = ProcessInfo.processInfo.thermalState
        if shown.contains(.battery), ticks.isMultiple(of: 5) { battery = batteryReader?.read() }
        if shown.contains(.network), wantsInterfaceUpdates, ticks.isMultiple(of: 10) { interface = networkSampler.primaryInterface() }
        if shown.contains(.storage), ticks.isMultiple(of: 30) { refreshStorage() }
        schedule(after: 1)
    }

    /// Starts sampling a metric: a fresh baseline for a rate, the current value of anything else, and
    /// an empty chart history. Slow values are read here and then only every few seconds.
    private func begin(_ metric: SystemMetric) {
        switch metric {
        case .cpu:
            cpuSampler.reset()
            _ = cpuSampler.sample()
            cpuHistory.removeAll()
        case .network:
            networkSampler.reset()
            _ = networkSampler.sample()
            downloadHistory.removeAll()
            uploadHistory.removeAll()
            interface = networkSampler.primaryInterface()
        case .disk:
            diskSampler.reset()
            _ = diskSampler.sample()
            diskReadHistory.removeAll()
            diskWriteHistory.removeAll()
        case .gpu:
            gpu = gpuReader?.read()
            gpuHistory.removeAll()
        case .memory:
            memory = MemoryReading.read()
        case .battery:
            battery = batteryReader?.read()
        case .storage:
            refreshStorage()
        }
    }

    private func updateUptime() {
        uptime = device.bootTime.map { Date.now.timeIntervalSince($0) }
    }

    private func refreshStorage() {
        guard storageTask == nil else { return }
        storageTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                Result { try StorageReading.readStartupVolume() }
            }.value
            guard let self, !Task.isCancelled else { return }
            self.storageTask = nil
            switch result {
            case .success(let reading): self.storage = reading
            case .failure(let error):
                FileHandle.standardError.write(Data("Toolsy: reading the startup volume failed: \(error)\n".utf8))
            }
        }
    }
}
