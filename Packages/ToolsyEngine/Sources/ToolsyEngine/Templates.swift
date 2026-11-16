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
        case bytes, rate, percent, duration, round
        case fixed(Int)
        case fallback(String)
    }

    enum Part: Sendable, Equatable {
        case text(String)
        case placeholder(key: String, filters: [Filter])
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
        parts.map { part in
            switch part {
            case .text(let text):
                return text
            case .placeholder(let key, let filters):
                return filters.reduce(state[key]) { value, filter in filter.apply(to: value) }?.text ?? ""
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
        let key = segments[0].trimmingCharacters(in: .whitespaces)
        guard ModManifest.isValidKey(key) else {
            throw SyntaxError("\"{{\(body)}}\" does not start with a valid state key")
        }
        var filters: [Filter] = []
        for segment in segments.dropFirst() {
            try filters.append(Filter(segment))
        }
        return .placeholder(key: key, filters: filters)
    }
}

extension ModTemplate.Filter {
    init(_ segment: Substring) throws(SyntaxError) {
        let colon = segment.firstIndex(of: ":")
        let name = segment[..<(colon ?? segment.endIndex)].trimmingCharacters(in: .whitespaces)
        // The text of `default:` is kept exactly as written, spaces included.
        let argument = colon.map { segment[segment.index(after: $0)...] }
        switch name {
        case "fixed":
            guard let argument, let decimals = Int(argument.trimmingCharacters(in: .whitespaces)), (0...10).contains(decimals) else {
                throw SyntaxError("fixed needs a number of decimals from 0 to 10, as in fixed:1")
            }
            self = .fixed(decimals)
        case "default":
            guard let argument else {
                throw SyntaxError("default needs a text, as in default:—")
            }
            self = .fallback(String(argument))
        case "bytes", "rate", "percent", "duration", "round":
            guard argument == nil else {
                throw SyntaxError("the filter \"\(name)\" takes no argument")
            }
            self = switch name {
            case "bytes": .bytes
            case "rate": .rate
            case "percent": .percent
            case "duration": .duration
            default: .round
            }
        default:
            throw SyntaxError("unknown filter \"\(name)\"")
        }
    }

    /// Numeric filters pass anything that is not a number through unchanged, so they chain with `default`.
    func apply(to value: JSONValue?) -> JSONValue? {
        if case .fallback(let text) = self {
            return (value?.text ?? "").isEmpty ? .string(text) : value
        }
        guard let number = value?.numberValue else { return value }
        return switch self {
        case .bytes: .string(Self.bytes(number))
        case .rate: .string(Self.bytes(number) + "/s")
        case .percent: .string(String(format: "%.0f%%", number))
        case .duration: .string(Self.duration(number))
        case .round: .number(number.rounded())
        case .fixed(let decimals): .string(String(format: "%.\(decimals)f", number))
        case .fallback: value
        }
    }

    /// Decimal units, as Finder shows them: `512 B`, `1.5 GB`, `12 MB`.
    static func bytes(_ count: Double) -> String {
        let units = ["B", "KB", "MB", "GB", "TB", "PB", "EB"]
        var scaled = count
        var unit = 0
        // 999.96 KB must become 1 MB, not "1000 KB".
        while abs(scaled) >= 999.95, unit < units.count - 1 {
            scaled /= 1000
            unit += 1
        }
        if unit == 0 {
            return String(format: "%.0f B", count)
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
