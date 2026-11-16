import SwiftUI
import ToolsyEngine
import ToolsyShared

/// A widget the dashboard can show now: a metric this Mac measures, or a widget of an installed mod.
/// Names and colours of a mod widget come from templates, so they are read only where they are shown
/// (the gallery, the options), never by the grid itself.
struct WidgetInfo: Identifiable {
    enum Content {
        case metric(SystemMetric)
        case mod(Mod, ModWidget)
    }

    let id: WidgetID
    let content: Content

    /// The widgets of this Mac's metrics and of the installed mods, built-in ones first.
    static func available(metrics: Set<SystemMetric>, mods: [Mod]) -> [WidgetInfo] {
        SystemMetric.allCases.filter(metrics.contains).map { WidgetInfo(id: .builtIn($0), content: .metric($0)) }
            + mods.flatMap { mod in
                mod.manifest.widgets.map { WidgetInfo(id: .mod(mod.id, widget: $0.id), content: .mod(mod, $0)) }
            }
    }

    /// What `id` names, unless it is a metric this Mac lacks or a widget of a mod that is not installed.
    static func resolve(_ id: WidgetID, metrics: Set<SystemMetric>, mods: ModsModel) -> WidgetInfo? {
        if let metric = id.metric {
            return metrics.contains(metric) ? WidgetInfo(id: id, content: .metric(metric)) : nil
        }
        guard let (modID, widgetID) = id.modWidget, let mod = mods.mod(id: modID),
              let widget = mod.manifest.widgets.first(where: { $0.id == widgetID }) else { return nil }
        return WidgetInfo(id: id, content: .mod(mod, widget))
    }

    var name: String {
        switch content {
        case .metric(let metric): metric.widgetName
        case .mod(let mod, let widget):
            widget.title.map(mod.render).flatMap { $0.isEmpty ? nil : $0 } ?? mod.manifest.name
        }
    }

    var symbol: String {
        switch content {
        case .metric(let metric): metric.widgetSymbol
        case .mod(let mod, let widget): widget.icon ?? mod.manifest.icon ?? "puzzlepiece.extension.fill"
        }
    }

    var tint: Color {
        switch content {
        case .metric(let metric): metric.widgetTint
        case .mod(let mod, let widget): Tint.resolve(widget.tint.map(mod.render)) ?? mod.tint
        }
    }

    /// Where the widget comes from, for the gallery.
    var source: String {
        switch content {
        case .metric: String(localized: "Built-in")
        case .mod(let mod, _): mod.manifest.name
        }
    }

    var defaultSize: WidgetSize {
        switch content {
        case .metric(let metric): metric == .network || metric == .disk ? .medium : .small
        case .mod(_, let widget): WidgetSize(widget.size)
        }
    }

    /// How its chart is drawn unless the user chooses otherwise; nil for a widget without a chart.
    var defaultChartStyle: ChartStyle? {
        switch content {
        case .metric(.cpu), .metric(.gpu): .area
        case .metric(.network), .metric(.disk): .line
        case .metric: nil
        case .mod(_, let widget): widget.chart.map { ChartStyle(rawValue: $0.style.rawValue) ?? .area }
        }
    }

    var offersRateUnit: Bool {
        id == .builtIn(.network)
    }
}

extension SystemMetric {
    var widgetName: String {
        switch self {
        case .cpu: String(localized: "CPU")
        case .memory: String(localized: "Memory")
        case .battery: String(localized: "Battery")
        case .network: String(localized: "Network")
        case .storage: String(localized: "Storage")
        case .gpu: String(localized: "GPU")
        case .disk: String(localized: "Disk Activity")
        }
    }

    var widgetSymbol: String {
        switch self {
        case .cpu: "cpu"
        case .memory: "memorychip"
        case .battery: "battery.75percent"
        case .network: "network"
        case .storage: "internaldrive"
        case .gpu: "cube"
        case .disk: "arrow.up.arrow.down"
        }
    }

    var widgetTint: Color {
        switch self {
        case .cpu, .storage: .blue
        case .memory, .battery: .green
        case .network: .cyan
        case .gpu: .purple
        case .disk: .teal
        }
    }
}
