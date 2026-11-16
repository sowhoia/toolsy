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
    /// Power flowing out of (negative) or into (positive) the battery, in watts.
    var watts: Double?
}

/// Reads the internal battery from IOKit power sources (charge, state, estimates) and the
/// `AppleSmartBattery` registry entry (cycle count, voltage and current).
final class BatteryReader {
    private let service: io_service_t

    init() {
        service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
    }

    deinit {
        if service != 0 { IOObjectRelease(service) }
    }

    /// The internal battery, or nil on a Mac without one.
    func read() -> BatteryReading? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        let battery = sources.lazy
            .compactMap { IOPSGetPowerSourceDescription(info, $0)?.takeUnretainedValue() as? [String: Any] }
            .first { $0[kIOPSTypeKey] as? String == kIOPSInternalBatteryType }
        guard let battery,
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
            watts: voltage.flatMap { volts in amperage.map { Double(volts) * Double($0) / 1_000_000 } }
        )
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
