import Foundation

/// A tile a mod adds to the dashboard: a caption, one headline value and an optional small visual,
/// like the tiles of the built-in metrics. The format is specified in `docs/MOD_FORMAT.md`, "Widgets".
public struct ModWidget: Decodable, Sendable, Equatable, Identifiable {
    /// How many of the dashboard's three columns the tile takes unless the user chooses otherwise.
    public enum Size: String, Decodable, Sendable, CaseIterable {
        case small, medium, wide

        public var columns: Int {
            switch self {
            case .small: 1
            case .medium: 2
            case .wide: 3
            }
        }
    }

    /// A sparkline under the value.
    public struct Chart: Decodable, Sendable, Equatable {
        public static let defaultPoints = 30

        public var series: [ModControl.Chart.Series]
        public var style: ModControl.Chart.Style
        /// How many samples of history to keep and show.
        public var points: Int
        /// Fixed lower bound of the value axis; fitted to the data when unset.
        public var min: Double?
        /// Fixed upper bound of the value axis; fitted to the data when unset.
        public var max: Double?

        private enum CodingKeys: String, CodingKey {
            case series, style, points, min, max
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            series = try container.decode([ModControl.Chart.Series].self, forKey: .series)
            style = try container.decodeIfPresent(ModControl.Chart.Style.self, forKey: .style) ?? .area
            points = try container.decodeIfPresent(Int.self, forKey: .points) ?? Self.defaultPoints
            min = try container.decodeIfPresent(Double.self, forKey: .min)
            max = try container.decodeIfPresent(Double.self, forKey: .max)
        }
    }

    /// A level bar under the value.
    public struct Gauge: Decodable, Sendable, Equatable {
        public var bind: String
        public var min: Double
        public var max: Double

        private enum CodingKeys: String, CodingKey {
            case bind, min, max
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            bind = try container.decode(String.self, forKey: .bind)
            min = try container.decodeIfPresent(Double.self, forKey: .min) ?? 0
            max = try container.decodeIfPresent(Double.self, forKey: .max) ?? 100
        }
    }

    /// Unique among the widgets of the mod; together with the mod's id it names the widget in the
    /// user's dashboard layout.
    public var id: String
    /// Template. The tile's caption; the mod's name when unset.
    public var title: String?
    /// SF Symbol name; the mod's icon when unset.
    public var icon: String?
    /// Template. The headline.
    public var value: String
    /// Template resolving to a colour or level name; the mod's tint when unset.
    public var tint: String?
    public var size: Size
    /// A widget shows at most one of `chart` and `gauge`.
    public var chart: Chart?
    public var gauge: Gauge?
    /// Controls shown under the tile's row while the tile is expanded. Without any, a click on the
    /// tile opens the mod's page.
    public var detail: [ModControl]
    /// Expression; the widget is on the dashboard only while it is truthy.
    public var when: String?

    private enum CodingKeys: String, CodingKey {
        case id, title, icon, value, tint, size, chart, gauge, detail, when
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        icon = try container.decodeIfPresent(String.self, forKey: .icon)
        value = try container.decode(String.self, forKey: .value)
        tint = try container.decodeIfPresent(String.self, forKey: .tint)
        size = try container.decodeIfPresent(Size.self, forKey: .size) ?? .small
        chart = try container.decodeIfPresent(Chart.self, forKey: .chart)
        gauge = try container.decodeIfPresent(Gauge.self, forKey: .gauge)
        detail = try container.decodeIfPresent([ModControl].self, forKey: .detail) ?? []
        when = try container.decodeIfPresent(String.self, forKey: .when)
    }
}

/// Something that happens to the Mac which a mod can answer with a command (`lifecycle.events`).
public enum ModSystemEvent: String, Decodable, Sendable, CaseIterable, CodingKeyRepresentable {
    /// Toolsy started, usually at login, with the mod on.
    case launch
    /// The Mac woke from sleep.
    case wake
    /// The network changed: another interface, address or route became the primary one.
    case network
    /// The power source changed between the adapter and the battery.
    case power

    /// What `TOOLSY_EVENT` says for a command started by this event.
    public var commandEvent: ModEvent {
        switch self {
        case .launch: .launch
        case .wake: .wake
        case .network: .network
        case .power: .power
        }
    }
}
