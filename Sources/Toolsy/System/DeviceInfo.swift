import Foundation
import IOKit

enum CoreKind: Equatable {
    case performance, efficiency
}

/// Facts about the Mac that do not change while the app runs.
struct DeviceInfo {
    /// Marketing name such as "MacBook Air (13-inch, M4, 2025)", or the model identifier.
    var model: String
    var chip: String
    var system: String
    var bootTime: Date?
    /// Kind of each logical CPU in the kernel's order, if the device tree tells.
    var coreKinds: [CoreKind]?

    /// SF Symbol of the kind of Mac. Model identifiers ("Mac16,12") no longer tell the kind
    /// apart, the marketing name does.
    var symbol: String {
        let kinds: [(String, String)] = [("MacBook", "laptopcomputer"), ("iMac", "desktopcomputer"),
                                         ("Mac mini", "macmini"), ("Mac Studio", "macstudio"), ("Mac Pro", "macpro.gen3")]
        return kinds.first { model.contains($0.0) }?.1 ?? "desktopcomputer"
    }

    static func current() -> DeviceInfo {
        let identifier = Sysctl.string("hw.model") ?? "Mac"
        let version = ProcessInfo.processInfo.operatingSystemVersion
        var system = "macOS \(version.majorVersion).\(version.minorVersion)"
        if version.patchVersion > 0 { system += ".\(version.patchVersion)" }
        if let build = Sysctl.string("kern.osversion") { system += " (\(build))" }
        let bootTime = Sysctl.value("kern.boottime", as: timeval.self).map {
            Date(timeIntervalSince1970: TimeInterval($0.tv_sec) + TimeInterval($0.tv_usec) / 1_000_000)
        }
        return DeviceInfo(
            model: deviceTreeString("IODeviceTree:/product", key: "product-name") ?? identifier,
            chip: Sysctl.string("machdep.cpu.brand_string") ?? identifier,
            system: system,
            bootTime: bootTime,
            coreKinds: readCoreKinds()
        )
    }

    private static func deviceTreeString(_ path: String, key: String) -> String? {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, path)
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        return string(entry, key)
    }

    private static func string(_ entry: io_registry_entry_t, _ key: String) -> String? {
        guard let data = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Data else { return nil }
        let text = String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
        return text.isEmpty ? nil : text
    }

    /// Apple silicon device trees list every CPU under `/cpus` with its cluster type.
    private static func readCoreKinds() -> [CoreKind]? {
        let cpus = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/cpus")
        guard cpus != 0 else { return nil }
        defer { IOObjectRelease(cpus) }
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(cpus, kIODeviceTreePlane, &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var kinds: [Int: CoreKind] = [:]
        while case let cpu = IOIteratorNext(iterator), cpu != 0 {
            defer { IOObjectRelease(cpu) }
            guard let cluster = string(cpu, "cluster-type"),
                  let id = IORegistryEntryCreateCFProperty(cpu, "logical-cpu-id" as CFString, kCFAllocatorDefault, 0)?
                      .takeRetainedValue() as? NSNumber else { continue }
            kinds[id.intValue] = cluster == "E" ? .efficiency : .performance
        }
        let count = ProcessInfo.processInfo.processorCount
        let ordered = (0..<count).compactMap { kinds[$0] }
        return ordered.count == count ? ordered : nil
    }
}
