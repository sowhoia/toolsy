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
