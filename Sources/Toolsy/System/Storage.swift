import Foundation

struct StorageReading: Equatable, Sendable {
    var volumeName: String
    var total: Int64
    /// Free space as Finder reports it: includes purgeable space macOS frees on demand.
    var available: Int64

    var used: Int64 { max(0, total - available) }

    /// Reads the startup volume. Computing purgeable space can take a moment, so call this off
    /// the main thread.
    nonisolated static func readStartupVolume() throws -> StorageReading {
        let keys: Set<URLResourceKey> = [.volumeLocalizedNameKey, .volumeTotalCapacityKey,
                                         .volumeAvailableCapacityForImportantUsageKey]
        let values = try URL(fileURLWithPath: "/").resourceValues(forKeys: keys)
        guard let total = values.volumeTotalCapacity,
              let available = values.volumeAvailableCapacityForImportantUsage else {
            throw CocoaError(.fileReadUnknown)
        }
        return StorageReading(volumeName: values.volumeLocalizedName ?? "Macintosh HD",
                              total: Int64(total), available: available)
    }
}
