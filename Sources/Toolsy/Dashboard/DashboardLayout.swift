import CoreGraphics
import ToolsyShared

/// Names a widget in the saved layout: a built-in one by its metric (`cpu`), a mod's as
/// `mod:<modID>/<widgetID>`. Any other text is kept as it is, so a layout naming a mod that is not
/// installed, or written by a newer Toolsy, survives being loaded and saved again.
struct WidgetID: Hashable, Codable, Sendable, RawRepresentable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    static func builtIn(_ metric: SystemMetric) -> WidgetID {
        WidgetID(rawValue: metric.rawValue)
    }

    /// The id of the widget `widgetID` of the mod `modID` (a mod id never contains a slash).
    static func mod(_ modID: String, widget widgetID: String) -> WidgetID {
        WidgetID(rawValue: "mod:\(modID)/\(widgetID)")
    }

    var metric: SystemMetric? {
        SystemMetric(rawValue: rawValue)
    }

    var modWidget: (modID: String, widgetID: String)? {
        guard rawValue.hasPrefix("mod:") else { return nil }
        let rest = rawValue.dropFirst(4)
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        let mod = rest[..<slash], widget = rest[rest.index(after: slash)...]
        guard !mod.isEmpty, !widget.isEmpty else { return nil }
        return (String(mod), String(widget))
    }
}

/// How many of the dashboard's three columns a tile takes.
enum WidgetSize: String, Codable, CaseIterable, Sendable {
    case small, medium, wide

    var columns: Int {
        switch self {
        case .small: 1
        case .medium: 2
        case .wide: 3
        }
    }

    init(_ size: ModWidget.Size) {
        switch size {
        case .small: self = .small
        case .medium: self = .medium
        case .wide: self = .wide
        }
    }
}

/// What a network rate is counted in.
enum RateUnit: String, Codable, CaseIterable, Sendable {
    case bytes, bits
}

extension ChartStyle: Codable {}

/// A widget on the dashboard and the options the user chose for it. An option left nil follows the
/// widget's own default (for a mod widget, its manifest), so a mod update can change it.
struct PlacedWidget: Codable, Equatable, Identifiable, Sendable {
    var id: WidgetID
    var size: WidgetSize?
    /// Only for widgets that draw a chart.
    var chartStyle: ChartStyle?
    /// Only for the network widget.
    var rateUnit: RateUnit?
}

/// The user's dashboard: the widgets in reading order and whether the device line is shown.
struct DashboardLayout: Codable, Equatable, Sendable {
    var showsDeviceLine = true
    var widgets: [PlacedWidget]

    /// What the dashboard showed before it could be customised: three small tiles over network and
    /// storage, or, without a battery, CPU, memory and storage over a full-width network tile.
    static func standard(hasBattery: Bool) -> DashboardLayout {
        let metrics: [SystemMetric] = hasBattery ? [.cpu, .memory, .battery, .network, .storage] : [.cpu, .memory, .storage, .network]
        return DashboardLayout(widgets: metrics.map {
            PlacedWidget(id: .builtIn($0), size: $0 == .network ? .medium : nil)
        })
    }
}

// MARK: Grid

/// A tile's place in the three-column grid.
nonisolated struct GridSlot: Equatable, Sendable {
    var row: Int
    var column: Int
    var span: Int
}

nonisolated enum GridPacking {
    static let columns = 3

    /// Places tiles that want `spans` columns, in order: a row takes tiles until the next one does not
    /// fit, and the last tile of a row that is not full stretches to its end, so the grid has no holes.
    static func pack(_ spans: [Int]) -> [GridSlot] {
        var slots: [GridSlot] = []
        var row = 0, column = 0
        func closeRow() {
            slots[slots.count - 1].span += columns - column
            row += 1
            column = 0
        }
        for wanted in spans {
            let span = min(max(wanted, 1), columns)
            if column + span > columns { closeRow() }
            slots.append(GridSlot(row: row, column: column, span: span))
            column += span
            if column == columns {
                row += 1
                column = 0
            }
        }
        if column > 0 { closeRow() }
        return slots
    }

    static func rowCount(_ slots: [GridSlot]) -> Int {
        slots.map(\.row).max().map { $0 + 1 } ?? 0
    }

    /// Where a dragged tile goes: the position in the order whose slot for it is under the pointer, or
    /// closest to it. It depends only on the pointer, so the tiles never flip back and forth while it rests.
    static func dropIndex(of dragged: Int, spans: [Int], at point: CGPoint, in geometry: GridGeometry) -> Int {
        var others = spans
        let span = others.remove(at: dragged)
        var best = (index: dragged, distance: CGFloat.infinity, centre: CGFloat.infinity)
        for index in 0...others.count {
            var order = others
            order.insert(span, at: index)
            let frame = geometry.frame(of: pack(order)[index])
            let dx = max(frame.minX - point.x, 0, point.x - frame.maxX)
            let dy = max(frame.minY - point.y, 0, point.y - frame.maxY)
            let distance = (dx * dx + dy * dy).squareRoot()
            let centre = hypot(frame.midX - point.x, frame.midY - point.y)
            if (distance, centre) < (best.distance, best.centre) {
                best = (index, distance, centre)
            }
        }
        return best.index
    }
}

/// Frames of grid slots for a grid of a given width whose rows are all `tileHeight` tall.
nonisolated struct GridGeometry: Equatable, Sendable {
    var width: CGFloat
    var tileHeight: CGFloat
    var spacing: CGFloat

    var columnWidth: CGFloat {
        max(0, (width - spacing * CGFloat(GridPacking.columns - 1)) / CGFloat(GridPacking.columns))
    }

    func width(ofSpan span: Int) -> CGFloat {
        columnWidth * CGFloat(span) + spacing * CGFloat(span - 1)
    }

    func frame(of slot: GridSlot) -> CGRect {
        CGRect(x: (columnWidth + spacing) * CGFloat(slot.column), y: (tileHeight + spacing) * CGFloat(slot.row),
               width: width(ofSpan: slot.span), height: tileHeight)
    }

    func height(rows: Int) -> CGFloat {
        rows > 0 ? tileHeight * CGFloat(rows) + spacing * CGFloat(rows - 1) : 0
    }
}
