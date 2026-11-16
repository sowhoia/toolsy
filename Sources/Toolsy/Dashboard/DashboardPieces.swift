import SwiftUI

extension EnvironmentValues {
    /// Room a tile's caption leaves free at its end, for the remove badge of edit mode.
    @Entry var tileCaptionInset: CGFloat = 0
}

/// The content of a widget's tile: a caption, one headline value and one small visual. The grid
/// cell around it makes it clickable, selectable or draggable.
struct TileFace<Visual: View>: View {
    let title: String
    let symbol: String
    let value: String
    @ViewBuilder let visual: Visual
    @Environment(\.tileCaptionInset) private var captionInset

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                SymbolImage(symbol)
                    .font(.system(size: 10, weight: .semibold))
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .padding(.trailing, captionInset)
            .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 17, weight: .semibold, design: .rounded).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .tickingValue()
            visual
                .frame(height: 16, alignment: .bottom)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(value)
    }
}

/// A thin level bar sitting on the bottom of a tile's visual area.
struct MiniBar: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        LevelBar(fraction: fraction, tint: tint, height: 5)
            .padding(.bottom, 3)
    }
}

/// The small chart of a tile: the newest samples, more of them the wider the tile.
struct Sparkline: View {
    let series: [ChartSeries]
    let style: ChartStyle
    var min: Double?
    var max: Double?
    let size: WidgetSize
    /// How many samples span the chart, when the data says so (a mod's chart); otherwise as many as
    /// suit the tile's size.
    var capacity: Int?

    /// How many samples span a tile of this size.
    static func capacity(_ size: WidgetSize) -> Int {
        size == .small ? 30 : 60
    }

    var body: some View {
        let capacity = capacity ?? Self.capacity(size)
        SeriesChart(series: series.map { ChartSeries($0.label, tint: $0.tint, values: $0.values.suffix(capacity)) },
                    style: style, min: min, max: max, capacity: capacity, height: 16, showsReadout: false)
    }
}

/// A caption-sized "label value" pair for detail views.
struct DetailFact: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Text(value)
                .font(.system(size: 13, weight: .medium).monospacedDigit())
                .lineLimit(1)
                .tickingValue()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// The slim line naming the Mac, its system, uptime and thermal state.
struct DeviceLine: View {
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
