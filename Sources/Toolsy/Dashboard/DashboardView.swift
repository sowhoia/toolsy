import SwiftUI

/// The metrics of the dashboard; at most one is expanded at a time.
private enum Metric: Hashable {
    case cpu, memory, battery, network, storage
}

/// A brief summary of the Mac at the top of the root page: a device line and a grid of small
/// metric tiles. Clicking a tile opens its details right under its row; clicking it again (or
/// another tile) closes them. Every tile reads only the readings it shows, so a new sample
/// re-renders only what changed, and details that are closed cost nothing.
struct DashboardView: View {
    @Environment(SystemMonitor.self) private var monitor
    @Environment(PanelState.self) private var panel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded: Metric?

    /// Width of one grid column: three columns fill the panel.
    private static let column = (Metrics.panelWidth - 2 * Metrics.panelPadding - 2 * Metrics.tileSpacing) / 3

    var body: some View {
        let hasBattery = monitor.battery != nil
        // Without a battery, storage moves up and network spans the whole second row.
        let top: [(Metric, Int)] = [(.cpu, 1), (.memory, 1), (hasBattery ? .battery : .storage, 1)]
        let bottom: [(Metric, Int)] = hasBattery ? [(.network, 2), (.storage, 1)] : [(.network, 3)]
        VStack(spacing: Metrics.tileSpacing) {
            DeviceLine()
            row(top)
            row(bottom)
        }
        .onChange(of: panel.isVisible) { _, visible in
            if !visible { expanded = nil }  // every opening starts collapsed
        }
        .onChange(of: expanded) { _, metric in
            monitor.wantsInterfaceUpdates = metric == .network
        }
    }

    /// A row of tiles, each spanning a number of the three grid columns.
    @ViewBuilder
    private func row(_ tiles: [(metric: Metric, span: Int)]) -> some View {
        let metrics = tiles.map(\.metric)
        HStack(spacing: Metrics.tileSpacing) {
            ForEach(tiles, id: \.metric) { metric, span in
                tile(metric)
                    .frame(width: Self.column * CGFloat(span) + Metrics.tileSpacing * CGFloat(span - 1))
                    .frame(maxHeight: .infinity)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        if let expanded, metrics.contains(expanded) {
            Tile { detail(expanded) }
                .id(expanded)
                .transition(reduceMotion ? .opacity : .asymmetric(
                    insertion: .scale(scale: 0.9, anchor: .top).combined(with: .opacity),
                    removal: .opacity
                ))
        }
    }

    private func toggle(_ metric: Metric) {
        withAnimation(Motion.resolve(Motion.gentle, reduceMotion: reduceMotion)) {
            expanded = expanded == metric ? nil : metric
        }
    }

    @ViewBuilder
    private func tile(_ metric: Metric) -> some View {
        let isExpanded = expanded == metric
        let action = { toggle(metric) }
        switch metric {
        case .cpu: CPUTile(isExpanded: isExpanded, action: action)
        case .memory: MemoryTile(isExpanded: isExpanded, action: action)
        case .battery: BatteryTile(isExpanded: isExpanded, action: action)
        case .network: NetworkTile(isExpanded: isExpanded, action: action)
        case .storage: StorageTile(isExpanded: isExpanded, action: action)
        }
    }

    @ViewBuilder
    private func detail(_ metric: Metric) -> some View {
        switch metric {
        case .cpu: CPUDetail()
        case .memory: MemoryDetail()
        case .battery: BatteryDetail()
        case .network: NetworkDetail()
        case .storage: StorageDetail()
        }
    }
}

// MARK: Shared pieces

/// A small clickable metric tile: a caption, one headline number and one small visual.
private struct MetricTile<Visual: View>: View {
    let title: String
    let symbol: String
    let value: String
    let numericValue: Double
    let isExpanded: Bool
    let action: () -> Void
    @ViewBuilder let visual: Visual

    var body: some View {
        Tile(tint: isExpanded ? .accentColor : nil, padding: 10, action: action) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Image(systemName: symbol)
                        .symbolRenderingMode(.hierarchical)
                        .font(.system(size: 10, weight: .semibold))
                    Text(title)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 17, weight: .semibold, design: .rounded).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    // Numbers that change every second morph rather than roll: `.numericText`
                    // blurs each glyph on the CPU and cost ~13 % CPU for these five tiles,
                    // `.interpolate` nothing measurable (M4, panel open, 8 s with top).
                    .contentTransition(.interpolate)
                    .animation(Motion.snappy, value: numericValue)
                visual
                    .frame(height: 16, alignment: .bottom)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(value)
        .accessibilityHint(isExpanded ? String(localized: "Hides details") : String(localized: "Shows details"))
        .accessibilityAddTraits(isExpanded ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { action() }
    }
}

/// A thin level bar sitting on the bottom of a tile's visual area.
private struct MiniBar: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        LevelBar(fraction: fraction, tint: tint, height: 5)
            .animation(Motion.gentle, value: fraction)
            .padding(.bottom, 3)
    }
}

/// A caption-sized "label value" pair for detail views.
private struct DetailFact: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Text(value)
                .font(.system(size: 13, weight: .medium).monospacedDigit())
                .lineLimit(1)
                .contentTransition(.interpolate)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

// MARK: Device

/// The slim line naming the Mac, its system, uptime and thermal state.
private struct DeviceLine: View {
    @Environment(SystemMonitor.self) private var monitor

    var body: some View {
        let device = monitor.device
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(device.model)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                StatusLabel(thermalText, level: thermalLevel)
                    .help(String(localized: "Thermal state"))
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: "\(device.chip) · \(device.system)")
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                if let uptime = monitor.uptime {
                    Label(Format.duration(uptime), systemImage: "clock")
                        .labelStyle(CompactLabelStyle())
                        .help(String(localized: "Uptime"))
                        .accessibilityLabel(String(localized: "Uptime"))
                        .accessibilityValue(Format.duration(uptime))
                }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var thermalText: String {
        switch monitor.thermalState {
        case .nominal: String(localized: "Cool")
        case .fair: String(localized: "Warm")
        case .serious: String(localized: "Hot")
        case .critical: String(localized: "Overheating")
        @unknown default: String(localized: "Unknown")
        }
    }

    private var thermalLevel: StatusLevel {
        switch monitor.thermalState {
        case .nominal, .fair: .ok
        case .serious: .warn
        case .critical: .error
        @unknown default: .off
        }
    }
}

private struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.font(.system(size: 9, weight: .medium))
            configuration.title
        }
    }
}

// MARK: CPU

private func cpuTint(_ load: CPULoad?) -> Color {
    (load?.total ?? 0) > 0.85 ? .orange : .blue
}

private struct CPUTile: View {
    let isExpanded: Bool
    let action: () -> Void
    @Environment(SystemMonitor.self) private var monitor

    var body: some View {
        let load = monitor.cpu
        MetricTile(title: String(localized: "CPU"), symbol: "cpu", value: load.map { Format.percent($0.total) } ?? "—",
                   numericValue: load?.total ?? 0, isExpanded: isExpanded, action: action) {
            SeriesChart(series: [ChartSeries(tint: cpuTint(load), values: monitor.cpuHistory.values.suffix(30))],
                        style: .area, min: 0, max: 100, capacity: 30, height: 16, showsReadout: false)
        }
    }
}

private struct CPUDetail: View {
    @Environment(SystemMonitor.self) private var monitor

    var body: some View {
        let load = monitor.cpu
        VStack(alignment: .leading, spacing: 10) {
            SeriesChart(String(localized: "Last minute"),
                        series: [ChartSeries(tint: cpuTint(load), values: monitor.cpuHistory.values)],
                        style: .area, min: 0, max: 100, capacity: 60, height: 44,
                        format: { Format.percent($0 / 100) })
            HStack(alignment: .bottom, spacing: 12) {
                CoreBars(cores: load?.cores ?? [], kinds: monitor.device.coreKinds)
                Spacer(minLength: 8)
                if let load {
                    Text(String(localized: "User \(Format.percent(load.user)) · System \(Format.percent(load.system))"))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .contentTransition(.interpolate)
                }
            }
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
        .animation(Motion.gentle, value: cores)
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
                ZStack(alignment: .bottom) {
                    Capsule().fill(Color.primary.opacity(0.1))
                    Capsule().fill(Color.blue.opacity(0.85))
                        .frame(height: max(3, 16 * loads[index]))
                }
                .frame(width: 4, height: 16)
            }
        }
        .help(help)
        .opacity(loads.isEmpty ? 0 : 1)
    }
}

// MARK: Memory

private func memoryTint(_ pressure: MemoryPressure?) -> Color {
    switch pressure {
    case .warning: .yellow
    case .critical: .red
    case .normal, nil: .green
    }
}

private struct MemoryTile: View {
    let isExpanded: Bool
    let action: () -> Void
    @Environment(SystemMonitor.self) private var monitor

    var body: some View {
        let memory = monitor.memory
        MetricTile(title: String(localized: "Memory"), symbol: "memorychip",
                   value: memory.map { Format.memory($0.used) } ?? "—",
                   numericValue: Double(memory?.used ?? 0), isExpanded: isExpanded, action: action) {
            MiniBar(fraction: memory.map { Double($0.used) / Double(max($0.total, 1)) } ?? 0,
                    tint: memoryTint(memory?.pressure))
        }
    }
}

private struct MemoryDetail: View {
    @Environment(SystemMonitor.self) private var monitor

    var body: some View {
        if let memory = monitor.memory {
            HStack(alignment: .center, spacing: 14) {
                RingGauge(value: Double(memory.used) / Double(max(memory.total, 1)) * 100,
                          text: Format.percent(Double(memory.used) / Double(max(memory.total, 1))),
                          tint: memoryTint(memory.pressure), size: 56)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(String(localized: "\(Format.memory(memory.used)) of \(Format.memory(memory.total))"))
                            .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        Spacer(minLength: 6)
                        StatusLabel(pressureText(memory.pressure), level: pressureLevel(memory.pressure))
                    }
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                        GridRow {
                            DetailFact(label: String(localized: "Apps"), value: Format.memory(memory.app))
                            DetailFact(label: String(localized: "Wired"), value: Format.memory(memory.wired))
                        }
                        GridRow {
                            DetailFact(label: String(localized: "Compressed"), value: Format.memory(memory.compressed))
                            DetailFact(label: String(localized: "Swap"), value: Format.memory(memory.swapUsed))
                        }
                    }
                }
            }
        }
    }

    private func pressureText(_ pressure: MemoryPressure) -> String {
        switch pressure {
        case .normal: String(localized: "Pressure normal")
        case .warning: String(localized: "Pressure elevated")
        case .critical: String(localized: "Pressure critical")
        }
    }

    private func pressureLevel(_ pressure: MemoryPressure) -> StatusLevel {
        switch pressure {
        case .normal: .ok
        case .warning: .warn
        case .critical: .error
        }
    }
}

// MARK: Battery

private func batteryTint(_ battery: BatteryReading) -> Color {
    if battery.isCharging || battery.isOnAC { return .green }
    return battery.percent <= 10 ? .red : battery.percent <= 20 ? .orange : .green
}

private struct BatteryTile: View {
    let isExpanded: Bool
    let action: () -> Void
    @Environment(SystemMonitor.self) private var monitor

    var body: some View {
        if let battery = monitor.battery {
            MetricTile(title: String(localized: "Battery"), symbol: symbol(battery),
                       value: Format.percent(Double(battery.percent) / 100), numericValue: Double(battery.percent),
                       isExpanded: isExpanded, action: action) {
                MiniBar(fraction: Double(battery.percent) / 100, tint: batteryTint(battery))
            }
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

private struct NetworkTile: View {
    let isExpanded: Bool
    let action: () -> Void
    @Environment(SystemMonitor.self) private var monitor

    var body: some View {
        let down = monitor.downloadRate.map(Format.rate) ?? "—"
        let up = monitor.uploadRate.map(Format.rate) ?? "—"
        MetricTile(title: String(localized: "Network"), symbol: monitor.interface?.displayName == "Wi-Fi" ? "wifi" : "network",
                   value: "↓\u{2009}\(down)  ↑\u{2009}\(up)",
                   numericValue: (monitor.downloadRate ?? 0) + (monitor.uploadRate ?? 0),
                   isExpanded: isExpanded, action: action) {
            SeriesChart(series: [ChartSeries(tint: .cyan, values: monitor.downloadHistory.values.suffix(30)),
                                 ChartSeries(tint: .orange, values: monitor.uploadHistory.values.suffix(30))],
                        style: .line, min: 0, capacity: 30, height: 16, showsReadout: false)
        }
    }
}

private struct NetworkDetail: View {
    @Environment(SystemMonitor.self) private var monitor

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SeriesChart(String(localized: "Last minute"),
                        series: [ChartSeries(String(localized: "Download"), tint: .cyan, values: monitor.downloadHistory.values),
                                 ChartSeries(String(localized: "Upload"), tint: .orange, values: monitor.uploadHistory.values)],
                        style: .line, min: 0, capacity: 60, height: 44, showsReadout: false)
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

private struct StorageTile: View {
    let isExpanded: Bool
    let action: () -> Void
    @Environment(SystemMonitor.self) private var monitor

    var body: some View {
        let storage = monitor.storage
        MetricTile(title: String(localized: "Free"), symbol: "internaldrive",
                   value: storage.map { Format.storage($0.available) } ?? "—",
                   numericValue: Double(storage?.available ?? 0), isExpanded: isExpanded, action: action) {
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
