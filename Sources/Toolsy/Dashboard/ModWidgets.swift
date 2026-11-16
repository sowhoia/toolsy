import SwiftUI
import ToolsyEngine
import ToolsyShared

/// The tile face of a mod's widget, rendered like a built-in one: its caption, its `value` and its
/// chart or gauge, in the mod's colours. Dimmed while the mod is switched off, still with its last value.
struct ModWidgetFace: View {
    let mod: Mod
    let widget: ModWidget
    let size: WidgetSize
    let chartStyle: ChartStyle
    private static let palette: [Color] = [.blue, .orange, .green, .pink, .purple, .teal]

    var body: some View {
        let tint = Tint.resolve(widget.tint.map(mod.render)) ?? mod.tint
        let title = widget.title.map(mod.render).flatMap { $0.isEmpty ? nil : $0 } ?? mod.manifest.name
        TileFace(title: title, symbol: widget.icon ?? mod.manifest.icon ?? "puzzlepiece.extension.fill",
                 value: mod.render(widget.value)) {
            if let chart = widget.chart {
                Sparkline(series: chart.series.enumerated().map { index, series in
                              ChartSeries(series.label, tint: Tint.resolve(series.tint) ?? (index == 0 ? tint : Self.palette[index - 1]),
                                          values: mod.history(of: series.bind))
                          },
                          style: chartStyle, min: chart.min, max: chart.max, size: size, capacity: capacity(of: chart))
            } else if let gauge = widget.gauge {
                MiniBar(fraction: fraction(of: mod.state[gauge.bind]?.numberValue, in: gauge), tint: tint)
            }
        }
        .opacity(mod.hasSwitch && !mod.isEnabled ? 0.5 : 1)
    }

    /// Series bound to arrays plot the whole array; recorded series show their newest `points`, as many
    /// as fit the tile.
    private func capacity(of chart: ModWidget.Chart) -> Int {
        let arrays = chart.series.compactMap { mod.state[$0.bind]?.arrayValue }
        if arrays.count == chart.series.count { return max(2, arrays.map(\.count).max() ?? 0) }
        return min(chart.points, Sparkline.capacity(size))
    }

    private func fraction(of value: Double?, in gauge: ModWidget.Gauge) -> Double {
        guard let value, value.isFinite, gauge.max > gauge.min else { return 0 }
        return min(max((value - gauge.min) / (gauge.max - gauge.min), 0), 1)
    }
}

/// A mod widget's `detail` under its row, laid out like the mod's page, and a row that opens the page.
struct ModWidgetDetail: View {
    let mod: Mod
    let widget: ModWidget
    @Environment(PanelState.self) private var panel

    var body: some View {
        let detail = widget.detail
        VStack(spacing: Metrics.tileSpacing) {
            ForEach(ModInterface.blocks(of: detail)) { block in
                switch block {
                case .section(let index):
                    ModControlView(mod: mod, control: detail[index], path: [index])
                case .group(let indices):
                    if indices.contains(where: { mod.isVisible(detail[$0]) }) {
                        SectionGroup {
                            ForEach(indices, id: \.self) { index in
                                ModControlView(mod: mod, control: detail[index], path: [index])
                            }
                        }
                    }
                }
            }
            SectionGroup {
                ListRow(String(localized: "Open “\(mod.manifest.name)”"), icon: mod.manifest.icon ?? "puzzlepiece.extension.fill",
                        tint: mod.tint) { panel.push(.mod(mod.id)) }
                    .debugAnchor("widget-open:\(mod.id)")
            }
        }
    }
}
