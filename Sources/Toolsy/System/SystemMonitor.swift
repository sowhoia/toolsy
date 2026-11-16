import Foundation
import Observation

/// Samples the Mac about once a second while the panel is visible and not at all otherwise.
///
/// Readings are kept when sampling stops, so reopening the panel shows the last values at once
/// instead of zeros; each start takes a fresh baseline for the rate-based readings (CPU,
/// network) and replaces the stale values a quarter of a second later.
@Observable
final class SystemMonitor {
    let device = DeviceInfo.current()
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

    @ObservationIgnored private let cpuSampler = CPUSampler()
    @ObservationIgnored private let networkSampler = NetworkSampler()
    @ObservationIgnored private let batteryReader: BatteryReader?
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

    init(simulateNoBattery: Bool = false) {
        batteryReader = simulateNoBattery ? nil : BatteryReader()
    }

    var isRunning: Bool { timer != nil }

    func start() {
        guard timer == nil else { return }
        cpuSampler.reset()
        networkSampler.reset()
        _ = cpuSampler.sample()
        _ = networkSampler.sample()
        readSlowValues()
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
        if let load = cpuSampler.sample() {
            cpu = load
            cpuHistory.append(load.total * 100)
        }
        if let rates = networkSampler.sample() {
            downloadRate = rates.download
            uploadRate = rates.upload
            downloadHistory.append(rates.download)
            uploadHistory.append(rates.upload)
        }
        memory = MemoryReading.read()
        updateUptime()
        thermalState = ProcessInfo.processInfo.thermalState
        if ticks.isMultiple(of: 5) { battery = batteryReader?.read() }
        if wantsInterfaceUpdates, ticks.isMultiple(of: 10) { interface = networkSampler.primaryInterface() }
        if ticks.isMultiple(of: 30) { refreshStorage() }
        schedule(after: 1)
    }

    /// Values that change slowly, read on start and every few seconds.
    private func readSlowValues() {
        memory = MemoryReading.read()
        battery = batteryReader?.read()
        interface = networkSampler.primaryInterface()
        thermalState = ProcessInfo.processInfo.thermalState
        updateUptime()
        refreshStorage()
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
