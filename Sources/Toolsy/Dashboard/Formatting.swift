import Foundation

/// Locale-aware formatting of the dashboard's numbers.
enum Format {
    static func percent(_ fraction: Double) -> String {
        fraction.formatted(.percent.precision(.fractionLength(0)))
    }

    /// Memory sizes in binary units, as Activity Monitor shows them.
    static func memory(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .memory)
    }

    /// Disk sizes in decimal units, as Finder shows them.
    static func storage(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        let amount = ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond.rounded()), countStyle: .file)
        return String(localized: "\(amount)/s")
    }

    /// Network speeds as providers state them: decimal bits per second.
    static func bitRate(_ bytesPerSecond: Double) -> String {
        let bits = max(bytesPerSecond, 0) * 8
        let units: [UnitInformationStorage] = [.bits, .kilobits, .megabits, .gigabits]
        let exponent = min(Int(log10(max(bits, 1)) / 3), units.count - 1)
        let amount = Measurement(value: bits / pow(1000, Double(exponent)), unit: units[exponent])
            .formatted(.measurement(width: .abbreviated, usage: .asProvided,
                                    numberFormatStyle: .number.precision(.fractionLength(exponent == 0 ? 0 : 1))))
        return String(localized: "\(amount)/s")
    }

    private static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter
    }()

    static func duration(_ seconds: TimeInterval) -> String {
        durationFormatter.string(from: max(60, seconds)) ?? "—"
    }

    static func watts(_ watts: Double) -> String {
        Measurement(value: abs(watts), unit: UnitPower.watts)
            .formatted(.measurement(width: .abbreviated, numberFormatStyle: .number.precision(.fractionLength(1))))
    }
}
