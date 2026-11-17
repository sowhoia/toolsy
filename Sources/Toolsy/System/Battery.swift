import Foundation
import IOKit
import IOKit.ps

struct BatteryReading: Equatable {
    var percent: Int
    var isCharging: Bool
    var isOnAC: Bool
    var isCharged: Bool
    /// Minutes, as macOS estimates them; nil while it is still calculating.
    var minutesToEmpty: Int?
    var minutesToFull: Int?
    var cycleCount: Int?
    /// The charge the battery holds when full, as a fraction of what it held new (its design capacity).
    var maximumCapacity: Double?
    /// Power flowing out of (negative) or into (positive) the battery, in watts.
    var watts: Double?
}

/// Reads the internal battery from IOKit power sources (charge, state, estimates) and the
/// `AppleSmartBattery` registry entry (cycle count, capacity, voltage and current).
final class BatteryReader {
    private let service: io_service_t

    init() {
        service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
    }

    deinit {
        if service != 0 { IOObjectRelease(service) }
    }

    /// Whether the Mac has an internal battery.
    static var isPresent: Bool {
        internalBattery() != nil
    }

    /// The internal battery, or nil on a Mac without one.
    func read() -> BatteryReading? {
        guard let battery = Self.internalBattery(),
              let current = battery[kIOPSCurrentCapacityKey] as? Int,
              let maximum = battery[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { return nil }

        func minutes(_ key: String) -> Int? {
            (battery[key] as? Int).flatMap { $0 >= 0 ? $0 : nil }  // -1 means "calculating"
        }
        let voltage = property("Voltage")  // mV
        let amperage = property("InstantAmperage") ?? property("Amperage")  // mA, signed
        return BatteryReading(
            percent: Int((Double(current) / Double(maximum) * 100).rounded()),
            isCharging: battery[kIOPSIsChargingKey] as? Bool ?? false,
            isOnAC: battery[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue,
            isCharged: battery[kIOPSIsChargedKey] as? Bool ?? false,
            minutesToEmpty: minutes(kIOPSTimeToEmptyKey),
            minutesToFull: minutes(kIOPSTimeToFullChargeKey),
            cycleCount: property("CycleCount").map(Int.init),
            maximumCapacity: Self.maximumCapacity(property),
            watts: voltage.flatMap { volts in amperage.map { Double(volts) * Double($0) / 1_000_000 } }
        )
    }

    /// The full charge capacity as a fraction of the design capacity, from the properties of the
    /// `AppleSmartBattery` entry: its normalized full charge capacity, else the raw one, both in mAh like
    /// the design capacity. Its `MaxCapacity` is no use: on Apple silicon it is the top of the charge's
    /// percentage scale, always 100. Nil when the battery does not report them. Not clamped: a new battery
    /// may hold a little more than it was designed for.
    static func maximumCapacity(_ property: (String) -> Int64?) -> Double? {
        guard let design = property("DesignCapacity"), design > 0,
              let full = property("NominalChargeCapacity") ?? property("AppleRawMaxCapacity"), full > 0 else { return nil }
        return Double(full) / Double(design)
    }

    /// The power source description of the internal battery.
    private static func internalBattery() -> [String: Any]? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        return sources.lazy
            .compactMap { IOPSGetPowerSourceDescription(info, $0)?.takeUnretainedValue() as? [String: Any] }
            .first { $0[kIOPSTypeKey] as? String == kIOPSInternalBatteryType }
    }

    private func property(_ key: String) -> Int64? {
        guard service != 0,
              let value = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
                  .takeRetainedValue() as? NSNumber else { return nil }
        // The registry stores the signed current as an unsigned 64-bit number; int64Value
        // reinterprets it correctly.
        return value.int64Value
    }
}
