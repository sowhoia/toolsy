import SwiftUI

// The built-in widgets: a face for the tile and a detail shown under its row. Each reads only the
// readings it shows, so a new sample re-renders only what changed.

/// The tile face of a built-in widget.
struct MetricFace: View {
    let metric: SystemMetric
    let size: WidgetSize
    let chartStyle: ChartStyle
    let rateUnit: RateUnit

    var body: some View {
        switch metric {
        case .cpu: CPUFace(size: size, style: chartStyle)
        case .memory: MemoryFace()
        case .battery: BatteryFace()
        case .network: NetworkFace(size: size, style: chartStyle, unit: rateUnit)
        case .storage: StorageFace()
        case .gpu: GPUFace(size: size, style: chartStyle)
        case .disk: DiskFace(size: size, style: chartStyle)
        }
    }
}

/// The detail of a built-in widget, shown under its row.
struct MetricDetail: View {
    let metric: SystemMetric
    let chartStyle: ChartStyle

    var body: some View {
        Tile {
            switch metric {
            case .cpu: CPUDetail(style: chartStyle)
            case .memory: MemoryDetail()
            case .battery: BatteryDetail()
            case .network: NetworkDetail(style: chartStyle)
            case .storage: StorageDetail()
            case .gpu: GPUDetail(style: chartStyle)
            case .disk: DiskDetail(style: chartStyle)
            }
        }
    }
}

// MARK: CPU

private func cpuTint(_ load: CPULoad?) -> Color {
    (load?.total ?? 0) > 0.85 ? .orange : .blue
}

private struct CPUFace: View {
    let size: WidgetSize
    let style: ChartStyle
    @Environment(SystemMonitor.self) private var monitor

    var body: some View {
        let load = monitor.cpu
        TileFace(title: String(localized: "CPU"), symbol: "cpu", value: load.map { Format.percent($0.total) } ?? "—") {
            Sparkline(series: [ChartSeries(tint: cpuTint(load), values: monitor.cpuHistory.values)],
                      style: style, min: 0, max: 100, size: size)
        }
    }
}

private struct CPUDetail: View {
    let style: ChartStyle
    @Environment(SystemMonitor.self) private var monitor

    var body: some View {
        let load = monitor.cpu
        VStack(alignment: .leading, spacing: 10) {
            SeriesChart(String(localized: "Last minute"),
                        series: [ChartSeries(tint: cpuTint(load), values: monitor.cpuHistory.values)],
                        style: style, min: 0, max: 100, capacity: 60, height: 44,
                        format: { Format.percent($0 / 100) })
            HStack(alignment: .bottom, spacing: 12) {
                CoreBars(cores: load?.cores ?? [], kinds: monitor.device.coreKinds)
                Spacer(minLength: 8)
                if let load {
                    Text(String(localized: "User \(Format.percent(load.user)) · System \(Format.percent(load.system))"))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            ProcessList(title: String(localized: "Using the most CPU"), measure: .cpu, count: 4)
        }
    }
}

/// One small bar per core, efficiency cores first when the device tree tells them apart.
private struct CoreBars: View {
    let cores: [Double]
    let kinds: [CoreKind]?

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if let kinds, kinds.count == cores.count {
                group(String(localized: "E"), help: String(localized: "Efficiency cores"),
                      loads: zip(kinds, cores).filter { $0.0 == .efficiency }.map(\.1))
                group(String(localized: "P"), help: String(localized: "Performance cores"),
                      loads: zip(kinds, cores).filter { $0.0 == .performance }.map(\.1))
            } else {
                group(nil, help: String(localized: "Cores"), loads: cores)
            }
        }
    }

    private func group(_ label: String?, help: String, loads: [Double]) -> some View {
        HStack(alignment: .bottom, spacing: 3) {
            if let label {
                Text(label)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.trailing, 1)
            }
            ForEach(loads.indices, id: \.self) { index in
                LevelColumn(fraction: loads[index], tint: Color.blue.opacity(0.85))
                    .frame(width: 4, height: 16)
            }
        }
        .help(help)
        .opacity(loads.isEmpty ? 0 : 1)
    }
}

// MARK: Memory

func memoryTint(_ pressure: MemoryPressure?) -> Color {
    switch pressure {
    case .warning: .yellow
    case .critical: .red
    case .normal, nil: .green
    }
}

private struct MemoryFace: View {
    @Environment(SystemMonitor.self) private var monitor

    var body: some View {
        let memory = monitor.memory
        TileFace(title: String(localized: "Memory"), symbol: "memorychip", value: memory.map { Format.memory($0.used) } ?? "—") {
            MiniBar(fraction: memory.map { Double($0.used) / Double(max($0.total, 1)) } ?? 0,
                    tint: memoryTint(memory?.pressure))
        }
    }
}

// MARK: Battery

private func batteryTint(_ battery: BatteryReading) -> Color {
    if battery.isCharging || battery.isOnAC { return .green }
    return battery.percent <= 10 ? .red : battery.percent <= 20 ? .orange : .green
}

private struct BatteryFace: View {
    @Environment(SystemMonitor.self) private var monitor

    var body: some View {
        let battery = monitor.battery
        TileFace(title: String(localized: "Battery"), symbol: battery.map(symbol) ?? "battery.100percent",
                 value: battery.map { Format.percent(Double($0.percent) / 100) } ?? "—") {
            MiniBar(fraction: battery.map { Double($0.percent) / 100 } ?? 0, tint: battery.map(batteryTint) ?? .green)
        }
    }

    private func symbol(_ battery: BatteryReading) -> String {
        if battery.isCharging { return "battery.100percent.bolt" }
        if battery.isOnAC { return "powerplug" }
        switch battery.percent {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}

private struct BatteryDetail: View {
    @Environment(SystemMonitor.self) private var monitor

    var body: some View {
        if let battery = monitor.battery {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(state(battery))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(battery.percent <= 10 && !battery.isOnAC ? Color.red : Color.primary)
                    Spacer(minLength: 6)
                    Text(Format.percent(Double(battery.percent) / 100))
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                LevelBar(fraction: Double(battery.percent) / 100, tint: batteryTint(battery), height: 6)
                HStack(spacing: 12) {
                    DetailFact(label: timeLabel(battery), value: time(battery) ?? "—")
                    DetailFact(label: battery.watts.map { $0 >= 0 ? String(localized: "Charging power") : String(localized: "Power draw") }
                                   ?? String(localized: "Power draw"),
                               value: battery.watts.map(Format.watts) ?? "—")
                    DetailFact(label: String(localized: "Cycles"), value: battery.cycleCount.map { "\($0)" } ?? "—")
                }
            }
        }
    }

    private func state(_ battery: BatteryReading) -> String {
        if battery.isCharged || (battery.isOnAC && battery.percent >= 100) { return String(localized: "Charged") }
        if battery.isCharging { return String(localized: "Charging") }
        if battery.isOnAC { return String(localized: "Not charging") }
        return String(localized: "On battery")
    }

    private func timeLabel(_ battery: BatteryReading) -> String {
        battery.isCharging ? String(localized: "Until full") : String(localized: "Time left")
    }

    private func time(_ battery: BatteryReading) -> String? {
        let minutes = battery.isCharging ? battery.minutesToFull : (battery.isOnAC ? nil : battery.minutesToEmpty)
        return minutes.map { Format.duration(Double($0) * 60) }
    }
}

// MARK: Network

private func rate(_ bytesPerSecond: Double, in unit: RateUnit) -> String {
    unit == .bits ? Format.bitRate(bytesPerSecond) : Format.rate(bytesPerSecond)
}

private struct NetworkFace: View {
    let size: WidgetSize
    let style: ChartStyle
    let unit: RateUnit
    @Environment(SystemMonitor.self) private var monitor

    var body: some View {
        TileFace(title: String(localized: "Network"), symbol: monitor.interface?.displayName == "Wi-Fi" ? "wifi" : "network",
                 value: value) {
            Sparkline(series: [ChartSeries(tint: .cyan, values: monitor.downloadHistory.values),
                               ChartSeries(tint: .orange, values: monitor.uploadHistory.values)],
                      style: style, min: 0, size: size)
        }
    }

    /// Both directions, or in a one-column tile, where they do not fit side by side, their sum.
    private var value: String {
        guard let down = monitor.downloadRate, let up = monitor.uploadRate else { return "—" }
        if size == .small { return rate(down + up, in: unit) }
        return "↓\u{2009}\(rate(down, in: unit))  ↑\u{2009}\(rate(up, in: unit))"
    }
}

private struct NetworkDetail: View {
    let style: ChartStyle
    @Environment(SystemMonitor.self) private var monitor

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SeriesChart(String(localized: "Last minute"),
                        series: [ChartSeries(String(localized: "Download"), tint: .cyan, values: monitor.downloadHistory.values),
                                 ChartSeries(String(localized: "Upload"), tint: .orange, values: monitor.uploadHistory.values)],
                        style: style, min: 0, capacity: 60, height: 44, showsReadout: false)
            if let interface = monitor.interface {
                ValueRow(interface.displayName, value: interface.address ?? interface.bsdName,
                         icon: interface.displayName == "Wi-Fi" ? "wifi" : "network", copyable: interface.address != nil)
            } else {
                ValueRow(String(localized: "Network"), value: String(localized: "Not connected"), icon: "network.slash")
            }
        }
    }
}

// MARK: Storage

private func storageTint(_ storage: StorageReading?) -> Color {
    guard let storage, storage.total > 0 else { return .blue }
    let free = Double(storage.available) / Double(storage.total)
    return free < 0.05 ? .red : free < 0.1 ? .orange : .blue
}

private struct StorageFace: View {
    @Environment(SystemMonitor.self) private var monitor

    var body: some View {
        let storage = monitor.storage
        TileFace(title: String(localized: "Free"), symbol: "internaldrive", value: storage.map { Format.storage($0.available) } ?? "—") {
            MiniBar(fraction: storage.map { Double($0.used) / Double(max($0.total, 1)) } ?? 0, tint: storageTint(storage))
        }
        .help(storage.map { String(localized: "free of \(Format.storage($0.total))") } ?? "")
    }
}

private struct StorageDetail: View {
    @Environment(SystemMonitor.self) private var monitor

    var body: some View {
        if let storage = monitor.storage {
            let used = Double(storage.used) / Double(max(storage.total, 1))
            HStack(spacing: 14) {
                RingGauge(value: used * 100, text: Format.percent(used), tint: storageTint(storage), size: 56)
                VStack(alignment: .leading, spacing: 8) {
                    Text(storage.volumeName).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    HStack(spacing: 12) {
                        DetailFact(label: String(localized: "Free"), value: Format.storage(storage.available))
                        DetailFact(label: String(localized: "Used"), value: Format.storage(storage.used))
                        DetailFact(label: String(localized: "Capacity"), value: Format.storage(storage.total))
                    }
                }
            }
        }
    }
}

// MARK: GPU

private struct GPUFace: View {
    let size: WidgetSize
    let style: ChartStyle
    @Environment(SystemMonitor.self) private var monitor

    var body: some View {
        TileFace(title: String(localized: "GPU"), symbol: "cube", value: monitor.gpu.map { Format.percent($0.utilization) } ?? "—") {
            Sparkline(series: [ChartSeries(tint: .purple, values: monitor.gpuHistory.values)],
                      style: style, min: 0, max: 100, size: size)
        }
    }
}

private struct GPUDetail: View {
    let style: ChartStyle
    @Environment(SystemMonitor.self) private var monitor

    var body: some View {
        let gpu = monitor.gpu
        VStack(alignment: .leading, spacing: 10) {
            SeriesChart(monitor.gpuModel ?? String(localized: "Last minute"),
                        series: [ChartSeries(tint: .purple, values: monitor.gpuHistory.values)],
                        style: style, min: 0, max: 100, capacity: 60, height: 44,
                        format: { Format.percent($0 / 100) })
            HStack(spacing: 12) {
                DetailFact(label: String(localized: "Rendering"), value: gpu?.renderer.map(Format.percent) ?? "—")
                DetailFact(label: String(localized: "Tiling"), value: gpu?.tiler.map(Format.percent) ?? "—")
                // Unified memory: in the binary units of every other memory figure, not the decimal ones of disks.
                DetailFact(label: String(localized: "Memory in use"), value: gpu?.memoryInUse.map { Format.memory(UInt64(clamping: $0)) } ?? "—")
            }
        }
    }
}

// MARK: Disk activity

private struct DiskFace: View {
    let size: WidgetSize
    let style: ChartStyle
    @Environment(SystemMonitor.self) private var monitor

    var body: some View {
        TileFace(title: String(localized: "Disk"), symbol: "arrow.up.arrow.down", value: value) {
            Sparkline(series: [ChartSeries(tint: .teal, values: monitor.diskReadHistory.values),
                               ChartSeries(tint: .pink, values: monitor.diskWriteHistory.values)],
                      style: style, min: 0, size: size)
        }
    }

    /// Reading and writing, in and out like Activity Monitor's "reads in" and "writes out" and the
    /// arrows of the network tile; in a one-column tile their sum.
    private var value: String {
        guard let disk = monitor.disk else { return "—" }
        if size == .small { return Format.rate(disk.readRate + disk.writeRate) }
        return "↓\u{2009}\(Format.rate(disk.readRate))  ↑\u{2009}\(Format.rate(disk.writeRate))"
    }
}

private struct DiskDetail: View {
    let style: ChartStyle
    @Environment(SystemMonitor.self) private var monitor

    var body: some View {
        let disk = monitor.disk
        VStack(alignment: .leading, spacing: 10) {
            SeriesChart(String(localized: "Last minute"),
                        series: [ChartSeries(String(localized: "Read"), tint: .teal, values: monitor.diskReadHistory.values),
                                 ChartSeries(String(localized: "Write"), tint: .pink, values: monitor.diskWriteHistory.values)],
                        style: style, min: 0, capacity: 60, height: 44, format: Format.rate)
            HStack(spacing: 12) {
                DetailFact(label: String(localized: "Read in total"), value: disk.map { Format.storage(Int64(clamping: $0.totalRead)) } ?? "—")
                DetailFact(label: String(localized: "Written in total"), value: disk.map { Format.storage(Int64(clamping: $0.totalWritten)) } ?? "—")
            }
        }
    }
}
