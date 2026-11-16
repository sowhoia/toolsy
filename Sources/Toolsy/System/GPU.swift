import Foundation
import IOKit

struct GPUReading: Equatable {
    /// Share of time the GPU was busy, 0...1.
    var utilization: Double
    /// The renderer and tiler stages of an Apple GPU, 0...1, where the driver reports them.
    var renderer: Double?
    var tiler: Double?
    /// Memory the GPU has in use, in bytes.
    var memoryInUse: Int64?
}

/// Reads GPU utilisation from the statistics the graphics driver publishes in the I/O Registry
/// (`IOAccelerator` → `PerformanceStatistics`), the numbers Activity Monitor's GPU history shows.
/// The driver keeps them current itself, so a read is one registry lookup and no baseline is needed.
final class GPUReader {
    private let service: io_service_t
    /// The GPU's name, such as "Apple M4".
    let model: String?

    private static let utilizationKey = "Device Utilization %"

    /// Nil on a Mac whose graphics driver does not report its utilisation.
    init?() {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }
        var found: io_service_t = 0
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            if found == 0, Self.statistics(of: entry)?[Self.utilizationKey] != nil {
                found = entry
            } else {
                IOObjectRelease(entry)
            }
        }
        guard found != 0 else { return nil }
        service = found
        model = IORegistryEntryCreateCFProperty(found, "model" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String
    }

    deinit {
        IOObjectRelease(service)
    }

    func read() -> GPUReading? {
        guard let statistics = Self.statistics(of: service),
              let utilization = statistics[Self.utilizationKey] as? NSNumber else { return nil }
        func fraction(_ key: String) -> Double? {
            (statistics[key] as? NSNumber).map { min(max($0.doubleValue / 100, 0), 1) }
        }
        return GPUReading(
            utilization: min(max(utilization.doubleValue / 100, 0), 1),
            renderer: fraction("Renderer Utilization %"),
            tiler: fraction("Tiler Utilization %"),
            memoryInUse: (statistics["In use system memory"] as? NSNumber)?.int64Value
        )
    }

    private static func statistics(of entry: io_registry_entry_t) -> [String: Any]? {
        IORegistryEntryCreateCFProperty(entry, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? [String: Any]
    }
}
