import SwiftUI
import Testing
@testable import Toolsy

struct TintTests {
    @Test func namesLevelsAndHexResolve() {
        #expect(Tint.color("teal") == .teal)
        #expect(Tint.color(" Blue ") == .blue)
        #expect(Tint.color("ok") == StatusLevel.ok.color)
        #expect(Tint.color("error") == .red)
        #expect(Tint.color("#FF0000") == Color(.sRGB, red: 1, green: 0, blue: 0))
        #expect(Tint.color("#00ff7f") == Color(.sRGB, red: 0, green: 1, blue: 127.0 / 255))
    }

    @Test func invalidValuesFallBack() {
        for value in [nil, "", "magenta", "#12345", "#1234567", "#GG0000", "#+12345", "123456"] {
            #expect(Tint.color(value, fallback: .purple) == .purple, "\(value ?? "nil")")
        }
    }
}

struct LabelOnTintTests {
    @Test func onlyLightTintsTakeADarkLabel() {
        for scheme in [ColorScheme.light, .dark] {
            #expect(Color.yellow.prefersDarkLabel(in: scheme))
            for tint in [Color.blue, .red, .green, .orange, .purple] {
                #expect(!tint.prefersDarkLabel(in: scheme), "\(tint) \(scheme)")
            }
        }
        // Teal is mid-tone in Light Mode and light in Dark Mode, where white on it is unreadable.
        #expect(!Color.teal.prefersDarkLabel(in: .light))
        #expect(Color.teal.prefersDarkLabel(in: .dark))
    }
}

struct FormatNumberTests {
    @Test func decimalsFollowTheStep() {
        let locale = Locale.current
        #expect(formatNumber(3, step: 1) == 3.formatted(.number.precision(.fractionLength(0)).locale(locale)))
        #expect(formatNumber(0.25, step: 0.25, unit: " s") == 0.25.formatted(.number.precision(.fractionLength(2))) + " s")
        #expect(formatNumber(42, unit: "%") == "42%")
    }
}

struct SampleHistoryTests {
    @Test func keepsTheNewestSamples() {
        var history = SampleHistory(capacity: 3)
        for value in [1.0, 2, 3, 4, .nan, 5] { history.append(value) }
        #expect(history.values == [3, 4, 5])
        history.removeAll()
        #expect(history.values.isEmpty && history.capacity == 3)
    }
}

struct SystemReadingTests {
    @Test func cpuLoadNeedsABaselineAndStaysInRange() throws {
        let sampler = CPUSampler()
        #expect(sampler.sample() == nil)
        Thread.sleep(forTimeInterval: 0.2)
        let load = try #require(sampler.sample())
        #expect((0...1).contains(load.total))
        #expect(load.cores.count == ProcessInfo.processInfo.processorCount)
    }

    @Test func memoryUsedIsAppWiredAndCompressed() throws {
        let memory = try #require(MemoryReading.read())
        #expect(memory.used == memory.app + memory.wired + memory.compressed)
        #expect(memory.used <= memory.total)
        #expect(memory.total == ProcessInfo.processInfo.physicalMemory)
    }

    @Test func networkRatesNeedABaseline() {
        let sampler = NetworkSampler()
        #expect(sampler.sample() == nil)
        #expect(NetworkSampler.readCounters() != nil)
    }

    @Test func startupVolumeHasSpace() throws {
        let storage = try StorageReading.readStartupVolume()
        #expect(storage.total > 0)
        #expect((0...storage.total).contains(storage.available))
    }
}

struct StepDecimalsTests {
    @Test func stepsAreWrittenExactly() {
        let two = { (value: Double) in value.formatted(.number.precision(.fractionLength(2))) }
        let one = { (value: Double) in value.formatted(.number.precision(.fractionLength(1))) }
        #expect(formatNumber(0.75, step: 0.25) == two(0.75))
        #expect(formatNumber(1.5, step: 0.5) == one(1.5))
        #expect(formatNumber(2, step: 1.5) == one(2))
    }
}

/// The interfaces the system knows, as `InterfaceNames` reads them.
private final class KnownInterfaces {
    var names = ["en0": "Wi-Fi"]
    private(set) var reads = 0

    func read() -> [String: String] {
        reads += 1
        return names
    }
}

struct PrimaryInterfaceTests {
    @Test func theIPv4EntryNamesItAndTheIPv6OneOnANetworkWithoutIPv4() {
        let ipv4: [String: Any] = ["PrimaryInterface": "en0", "Router": "192.168.0.1"]
        let ipv6: [String: Any] = ["PrimaryInterface": "en7", "Router": "fe80::1"]
        #expect(NetworkSampler.primaryInterfaceName(ipv4: ipv4, ipv6: ipv6) == "en0")
        #expect(NetworkSampler.primaryInterfaceName(ipv4: nil, ipv6: ipv6) == "en7")
        #expect(NetworkSampler.primaryInterfaceName(ipv4: ["Router": "192.168.0.1"], ipv6: ipv6) == "en7")
        #expect(NetworkSampler.primaryInterfaceName(ipv4: nil, ipv6: nil) == nil)
        #expect(NetworkSampler.primaryInterfaceName(ipv4: "en0", ipv6: ["PrimaryInterface": 7]) == nil)
    }

    @Test func namesAreReadAgainForAnInterfaceTheyLack() {
        let known = KnownInterfaces()
        var names = InterfaceNames(read: known.read)
        #expect(names.displayName(of: "en0") == "Wi-Fi")
        #expect(names.displayName(of: "en0") == "Wi-Fi")
        #expect(known.reads == 1, "read once")

        // An adapter plugged in after the names were read.
        known.names["en7"] = "USB 10/100/1000 LAN"
        #expect(names.displayName(of: "en7") == "USB 10/100/1000 LAN")
        #expect(known.reads == 2)

        // A tunnel never has a name of its own: it is a VPN, and not worth reading the names again for.
        #expect(names.displayName(of: "utun4") == "VPN")
        #expect(names.displayName(of: "ipsec0") == "VPN")
        #expect(known.reads == 2)

        // Still unknown after reading again: its BSD name.
        #expect(names.displayName(of: "en9") == "en9")
        #expect(known.reads == 3)
    }
}

struct BatteryHealthTests {
    /// The `AppleSmartBattery` entry of an Apple silicon MacBook (`ioreg -rn AppleSmartBattery`).
    private let entry: [String: Int64] = ["DesignCapacity": 4629, "NominalChargeCapacity": 4399, "AppleRawMaxCapacity": 4272,
                                          "MaxCapacity": 100, "CycleCount": 150]

    @Test func maximumCapacityIsTheFullChargeOverTheDesignCapacity() {
        #expect(BatteryReader.maximumCapacity { entry[$0] } == 4399.0 / 4629)
        var raw = entry
        raw["NominalChargeCapacity"] = nil
        #expect(BatteryReader.maximumCapacity { raw[$0] } == 4272.0 / 4629, "without the normalized figure, the raw one")
        // A new battery may hold a little more than it was designed for.
        let new: [String: Int64] = ["DesignCapacity": 4629, "NominalChargeCapacity": 4700]
        #expect(BatteryReader.maximumCapacity { new[$0] } == 4700.0 / 4629)
    }

    @Test func withoutBothCapacitiesItIsUnknown() {
        let entries: [[String: Int64]] = [
            ["DesignCapacity": 4629, "MaxCapacity": 100],  // only a percentage of the full charge
            ["NominalChargeCapacity": 4399, "AppleRawMaxCapacity": 4272],
            ["DesignCapacity": 0, "NominalChargeCapacity": 4399],
            ["DesignCapacity": 4629, "NominalChargeCapacity": 0],
            [:],
        ]
        for entry in entries {
            #expect(BatteryReader.maximumCapacity { entry[$0] } == nil, "\(entry)")
        }
    }

    @Test(.enabled("on a Mac with a battery") { await BatteryReader.isPresent })
    func thisMacReportsItsBatteryHealth() throws {
        let reading = try #require(BatteryReader().read())
        let capacity = try #require(reading.maximumCapacity)
        #expect((0.3...1.2).contains(capacity))
        #expect(reading.cycleCount != nil)
    }
}

struct RowReorderingTests {
    @Test func aDraggedRowLandsAtTheNearestBoundaryWithinTheList() {
        let height: CGFloat = 40
        #expect(RowReordering.target(start: 3, translation: -80, rowHeight: height, count: 4) == 1)
        #expect(RowReordering.target(start: 3, translation: -19, rowHeight: height, count: 4) == 3)
        #expect(RowReordering.target(start: 3, translation: -21, rowHeight: height, count: 4) == 2)
        #expect(RowReordering.target(start: 0, translation: 61, rowHeight: height, count: 4) == 2)
        #expect(RowReordering.target(start: 1, translation: 1000, rowHeight: height, count: 4) == 3)
        #expect(RowReordering.target(start: 1, translation: -1000, rowHeight: height, count: 4) == 0)
        #expect(RowReordering.target(start: 0, translation: 50, rowHeight: 0, count: 4) == 0)
    }

    @Test func theRowsBetweenStepTowardsWhereTheDraggedOneCameFrom() {
        let height: CGFloat = 40
        // The last of four rows over the second: the second and third step down.
        #expect((0..<4).map { RowReordering.shift(of: $0, start: 3, target: 1, rowHeight: height) } == [0, 40, 40, 0])
        // The first over the third: the second and third step up.
        #expect((0..<4).map { RowReordering.shift(of: $0, start: 0, target: 2, rowHeight: height) } == [0, -40, -40, 0])
        // Over its own place, nothing moves.
        #expect((0..<4).map { RowReordering.shift(of: $0, start: 2, target: 2, rowHeight: height) } == [0, 0, 0, 0])
    }
}
