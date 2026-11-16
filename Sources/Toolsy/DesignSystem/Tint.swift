import SwiftUI

/// A mod's status level (MOD_FORMAT.md, "State": `level`).
enum StatusLevel: String, CaseIterable, Sendable {
    case ok, warn, error, off

    var color: Color {
        switch self {
        case .ok: .green
        case .warn: .orange
        case .error: .red
        case .off: .secondary
        }
    }
}

/// Resolves a `tint` value as MOD_FORMAT.md "Colours" defines it: a colour name, a level name or
/// `#RRGGBB`. Anything else, including an empty template result, gives `fallback`.
enum Tint {
    static func color(_ value: String?, fallback: Color = .accentColor) -> Color {
        resolve(value) ?? fallback
    }

    /// The colour `value` names, or nil when it names none, so a caller can keep its own default
    /// (a value row stays secondary while its `"{{level}}"` tint is still empty).
    static func resolve(_ value: String?) -> Color? {
        guard let raw = value?.trimmingCharacters(in: .whitespaces).lowercased(), !raw.isEmpty else {
            return nil
        }
        if let named = named[raw] { return named }
        if let level = StatusLevel(rawValue: raw) { return level.color }
        return hex(raw)
    }

    private static let named: [String: Color] = [
        "red": .red, "orange": .orange, "yellow": .yellow, "green": .green, "mint": .mint,
        "teal": .teal, "cyan": .cyan, "blue": .blue, "indigo": .indigo, "purple": .purple,
        "pink": .pink, "brown": .brown, "gray": .gray,
    ]

    private static func hex(_ text: String) -> Color? {
        let digits = text.dropFirst()
        // `UInt32(_:radix:)` would also accept a sign, so check the digits first.
        guard text.first == "#", digits.count == 6, digits.allSatisfy(\.isHexDigit),
              let rgb = UInt32(digits, radix: 16) else {
            return nil
        }
        return Color(
            .sRGB,
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255
        )
    }
}
