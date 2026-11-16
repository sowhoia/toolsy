import Foundation
import ToolsyShared

/// A syntax error in a template or expression. The engine prefixes it with the manifest path it was found at.
public struct SyntaxError: LocalizedError, Equatable, Sendable {
    public let message: String

    init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}

/// Text with `{{key}}` / `{{key|filter|…}}` placeholders, as specified in MOD_FORMAT.md ("Templates").
public struct ModTemplate: Sendable, Equatable {
    enum Filter: Sendable, Equatable {
        case bytes, rate, bitrate, percent, duration, round, number, time, date, ago, upper, lower, count
        case fixed(Int)
        case truncate(Int)
        case join(String)
        case multiply(Double), divide(Double), add(Double)
        case fallback(String)
        case either(String, String)
    }

    enum Part: Sendable, Equatable {
        case text(String)
        case placeholder(StatePath, filters: [Filter])
    }

    let parts: [Part]

    public init(_ source: String) throws(SyntaxError) {
        var parts: [Part] = []
        var rest = source[...]
        while let open = rest.range(of: "{{") {
            try parts.append(Self.literal(rest[..<open.lowerBound]))
            let inside = rest[open.upperBound...]
            guard let close = inside.range(of: "}}"), !inside[..<close.lowerBound].contains("{{") else {
                throw SyntaxError("\"{{\" is not closed")
            }
            try parts.append(Self.placeholder(inside[..<close.lowerBound]))
            rest = inside[close.upperBound...]
        }
        try parts.append(Self.literal(rest))
        self.parts = parts
    }

    public func render(_ state: ModState) -> String {
        render(state, in: .current)
    }

    func render(_ state: ModState, in context: FormatContext) -> String {
        parts.map { part in
            switch part {
            case .text(let text): text
            case .placeholder(let path, let filters): Filter.apply(filters, to: path.value(in: state), in: context)
            }
        }.joined()
    }

    private static func literal(_ text: Substring) throws(SyntaxError) -> Part {
        guard !text.contains("}}") else {
            throw SyntaxError("\"}}\" has no matching \"{{\"")
        }
        return .text(String(text))
    }

    private static func placeholder(_ body: Substring) throws(SyntaxError) -> Part {
        let segments = body.split(separator: "|", omittingEmptySubsequences: false)
        guard let path = StatePath(segments[0].trimmingCharacters(in: .whitespaces)) else {
            throw SyntaxError("\"{{\(body)}}\" does not start with a valid state key or path")
        }
        return .placeholder(path, filters: try Filter.chain(segments.dropFirst()))
    }
}

/// The locale, time zone and clock the filters `number`, `time`, `date` and `ago` format for.
struct FormatContext: Sendable {
    var locale: Locale
    var timeZone: TimeZone
    var now: Date

    static var current: FormatContext {
        FormatContext(locale: .autoupdatingCurrent, timeZone: .autoupdatingCurrent, now: .now)
    }
}

/// A filter chain applied to a number: the `format` of gauges and charts, e.g. `"div:1000|fixed:1"`.
public struct ModValueFormat: Sendable, Equatable {
    let filters: [ModTemplate.Filter]

    public init(_ chain: String) throws(SyntaxError) {
        filters = try ModTemplate.Filter.chain(chain.split(separator: "|", omittingEmptySubsequences: false))
    }

    public func string(for value: Double) -> String {
        string(for: value, in: .current)
    }

    func string(for value: Double, in context: FormatContext) -> String {
        ModTemplate.Filter.apply(filters, to: .number(value), in: context)
    }
}

extension ModTemplate.Filter {
    static func chain(_ segments: some Sequence<Substring>) throws(SyntaxError) -> [Self] {
        var filters: [Self] = []
        for segment in segments {
            try filters.append(Self(segment))
        }
        return filters
    }

    /// Applies `filters` left to right and renders the result as text; a missing value renders nothing.
    static func apply(_ filters: [Self], to value: JSONValue?, in context: FormatContext) -> String {
        filters.reduce(value) { value, filter in filter.apply(to: value, in: context) }?.text ?? ""
    }

    init(_ segment: Substring) throws(SyntaxError) {
        let colon = segment.firstIndex(of: ":")
        let name = segment[..<(colon ?? segment.endIndex)].trimmingCharacters(in: .whitespaces)
        // Texts (`default:`, `join:`, `either:`) are kept exactly as written, spaces included.
        let argument = colon.map { segment[segment.index(after: $0)...] }
        func integer(in range: ClosedRange<Int>) -> Int? {
            argument.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }.flatMap { range.contains($0) ? $0 : nil }
        }
        func number() -> Double? {
            guard let text = argument?.trimmingCharacters(in: .whitespaces), text.wholeMatch(of: /-?[0-9]+(?:\.[0-9]+)?/) != nil else {
                return nil
            }
            return Double(text)
        }
        switch name {
        case "fixed":
            guard let decimals = integer(in: 0...10) else {
                throw SyntaxError("fixed needs a number of decimals from 0 to 10, as in fixed:1")
            }
            self = .fixed(decimals)
        case "truncate":
            guard let length = integer(in: 1...500) else {
                throw SyntaxError("truncate needs a length from 1 to 500, as in truncate:20")
            }
            self = .truncate(length)
        case "default":
            guard let argument else {
                throw SyntaxError("default needs a text, as in default:—")
            }
            self = .fallback(String(argument))
        case "join":
            self = .join(argument.map(String.init) ?? ", ")
        case "mul", "add":
            guard let operand = number() else {
                throw SyntaxError("\(name) needs a number, as in \(name):8")
            }
            self = name == "mul" ? .multiply(operand) : .add(operand)
        case "div":
            guard let divisor = number(), divisor != 0 else {
                throw SyntaxError("div needs a number other than 0, as in div:1000")
            }
            self = .divide(divisor)
        case "either":
            guard let argument, let separator = argument.firstIndex(of: ":") else {
                throw SyntaxError("either needs two texts separated by \":\", as in either:on:off")
            }
            self = .either(String(argument[..<separator]), String(argument[argument.index(after: separator)...]))
        default:
            let plain: [String: Self] = [
                "bytes": .bytes, "rate": .rate, "bitrate": .bitrate, "percent": .percent, "duration": .duration,
                "round": .round, "number": .number, "time": .time, "date": .date, "ago": .ago,
                "upper": .upper, "lower": .lower, "count": .count,
            ]
            guard let filter = plain[name] else {
                throw SyntaxError("unknown filter \"\(name)\"")
            }
            guard argument == nil else {
                throw SyntaxError("the filter \"\(name)\" takes no argument")
            }
            self = filter
        }
    }

    /// Each filter acts on the kind of value it is made for and passes anything else through unchanged,
    /// so filters chain with `default`. Numeric filters in particular leave non-numbers alone.
    func apply(to value: JSONValue?, in context: FormatContext) -> JSONValue? {
        switch (self, value) {
        case (.fallback(let text), _):
            return (value?.text ?? "").isEmpty ? .string(text) : value
        case (.either(let yes, let no), _):
            return .string(value?.isTruthy == true ? yes : no)
        case (.upper, .string(let text)?):
            return .string(text.uppercased())
        case (.lower, .string(let text)?):
            return .string(text.lowercased())
        case (.truncate(let length), .string(let text)?):
            guard text.count > length else { return value }
            return .string(String(text.prefix(length - 1)).replacing(/\s+$/, with: "") + "…")
        case (.count, .string(let text)?):
            return .number(Double(text.count))
        case (.count, .array(let array)?):
            return .number(Double(array.count))
        case (.count, .object(let object)?):
            return .number(Double(object.count))
        case (.join(let separator), .array(let array)?):
            return .string(array.filter(\.isScalar).map(\.text).joined(separator: separator))
        case (_, .number(let number)?):
            return apply(to: number, in: context) ?? value
        default:
            return value
        }
    }

    /// The numeric filters; nil for the others, which leave a number unchanged.
    private func apply(to number: Double, in context: FormatContext) -> JSONValue? {
        switch self {
        case .bytes: .string(Self.bytes(number))
        case .rate: .string(Self.bytes(number) + "/s")
        case .bitrate: .string(Self.scaled(number * 8, units: ["bit/s", "kbit/s", "Mbit/s", "Gbit/s"]))
        case .percent: .string(String(format: "%.0f%%", number))
        case .duration: .string(Self.duration(number))
        case .round: .number(number.rounded())
        case .fixed(let decimals): .string(String(format: "%.\(decimals)f", number))
        case .number: .string(number.formatted(.number.precision(.fractionLength(0...2)).locale(context.locale)))
        case .time:
            .string(Date(timeIntervalSince1970: number).formatted(
                Date.FormatStyle(date: .omitted, time: .shortened, locale: context.locale, timeZone: context.timeZone)))
        case .date:
            .string(Date(timeIntervalSince1970: number).formatted(
                Date.FormatStyle(date: .numeric, time: .omitted, locale: context.locale, timeZone: context.timeZone)))
        case .ago: .string(Self.ago(number, in: context))
        case .multiply(let factor): Self.finite(number * factor)
        case .divide(let divisor): Self.finite(number / divisor)
        case .add(let term): Self.finite(number + term)
        case .upper, .lower, .truncate, .count, .join, .fallback, .either: nil
        }
    }

    /// Arithmetic that overflows renders nothing rather than "inf".
    private static func finite(_ number: Double) -> JSONValue? {
        number.isFinite ? .number(number) : .null
    }

    static func ago(_ seconds: Double, in context: FormatContext) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = context.locale
        // "5 min. ago", "now", "yesterday"; the abbreviated style reads "-5 мин" in Russian.
        formatter.unitsStyle = .short
        formatter.dateTimeStyle = .named
        return formatter.localizedString(for: Date(timeIntervalSince1970: seconds), relativeTo: context.now)
    }

    /// Decimal units, as Finder shows them: `512 B`, `1.5 GB`, `12 MB`.
    static func bytes(_ count: Double) -> String {
        scaled(count, units: ["B", "KB", "MB", "GB", "TB", "PB", "EB"])
    }

    /// `count` in steps of 1000 through `units`, with at most one decimal.
    static func scaled(_ count: Double, units: [String]) -> String {
        var scaled = count
        var unit = 0
        // 999.96 KB must become 1 MB, not "1000 KB".
        while abs(scaled) >= 999.95, unit < units.count - 1 {
            scaled /= 1000
            unit += 1
        }
        if unit == 0 {
            return String(format: "%.0f \(units[0])", count)
        }
        let tenths = (scaled * 10).rounded() / 10
        let digits = tenths == tenths.rounded() ? String(format: "%.0f", tenths) : String(format: "%.1f", tenths)
        return "\(digits) \(units[unit])"
    }

    /// The two largest units: `45s`, `3m 20s`, `2h 05m`, `1d 4h`.
    static func duration(_ seconds: Double) -> String {
        let sign = seconds < 0 ? "-" : ""
        let total = abs(seconds).rounded(.down)
        let days = (total / 86_400).rounded(.down)
        let hours = (total.truncatingRemainder(dividingBy: 86_400) / 3_600).rounded(.down)
        let minutes = (total.truncatingRemainder(dividingBy: 3_600) / 60).rounded(.down)
        let secs = total.truncatingRemainder(dividingBy: 60)
        func whole(_ value: Double) -> String { String(format: "%.0f", value) }
        func padded(_ value: Double) -> String { String(format: "%02.0f", value) }
        if days > 0 { return "\(sign)\(whole(days))d \(whole(hours))h" }
        if hours > 0 { return "\(sign)\(whole(hours))h \(padded(minutes))m" }
        if minutes > 0 { return "\(sign)\(whole(minutes))m \(padded(secs))s" }
        return "\(sign)\(whole(secs))s"
    }
}
