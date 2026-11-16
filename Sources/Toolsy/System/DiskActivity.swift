import Foundation
import IOKit

struct DiskActivity: Equatable {
    /// Bytes per second since the previous sample.
    var readRate: Double
    var writeRate: Double
    /// Bytes moved since each disk appeared: for the internal disk, since startup.
    var totalRead: UInt64
    var totalWritten: UInt64
}

/// Read and write rates of the Mac's disks from the byte counters of their block storage drivers
/// (`IOBlockStorageDriver` → `Statistics`). Disk images are left out: what they read and write also
/// reaches the disk that holds their file, so counting them would count it twice.
final class DiskActivitySampler {
    struct Counters: Equatable {
        var read: UInt64
        var written: UInt64
    }

    private var previous: (counters: [UInt64: Counters], time: ContinuousClock.Instant)?

    func reset() {
        previous = nil
    }

    /// Activity since the previous call; nil for the first call (the baseline).
    func sample() -> DiskActivity? {
        let counters = Self.readCounters()
        let now = ContinuousClock.now
        defer { previous = (counters, now) }
        guard let previous else { return nil }
        let elapsed = (now - previous.time) / .seconds(1)
        guard elapsed > 0 else { return nil }
        var read: UInt64 = 0, written: UInt64 = 0
        // Disks that appeared, vanished or were reset since the last sample add nothing.
        for (disk, current) in counters {
            guard let old = previous.counters[disk] else { continue }
            read += current.read >= old.read ? current.read - old.read : 0
            written += current.written >= old.written ? current.written - old.written : 0
        }
        return DiskActivity(readRate: Double(read) / elapsed, writeRate: Double(written) / elapsed,
                            totalRead: counters.values.reduce(0) { $0 + $1.read },
                            totalWritten: counters.values.reduce(0) { $0 + $1.written })
    }

    /// The counters of every disk that is not a disk image, by registry entry id.
    static func readCounters() -> [UInt64: Counters] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS else {
            return [:]
        }
        defer { IOObjectRelease(iterator) }
        var counters: [UInt64: Counters] = [:]
        while case let driver = IOIteratorNext(iterator), driver != 0 {
            defer { IOObjectRelease(driver) }
            guard !isDiskImage(driver),
                  let statistics = IORegistryEntryCreateCFProperty(driver, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                      .takeRetainedValue() as? [String: Any],
                  let read = statistics["Bytes (Read)"] as? NSNumber,
                  let written = statistics["Bytes (Write)"] as? NSNumber else { continue }
            var id: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(driver, &id) == KERN_SUCCESS else { continue }
            counters[id] = Counters(read: read.uint64Value, written: written.uint64Value)
        }
        return counters
    }

    /// A disk image's device says it is connected through a file.
    private static func isDiskImage(_ driver: io_registry_entry_t) -> Bool {
        let characteristics = IORegistryEntrySearchCFProperty(
            driver, kIOServicePlane, "Protocol Characteristics" as CFString, kCFAllocatorDefault,
            IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
        ) as? [String: Any]
        return characteristics?["Physical Interconnect Location"] as? String == "File"
    }
}
