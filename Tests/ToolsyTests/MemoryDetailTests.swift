import Foundation
import Testing
import ToolsyShared
@testable import Toolsy

private let gigabyte: UInt64 = 1 << 30
private let total = 16 * gigabyte

private func finished(freed: UInt64, cacheFlushed: Bool = true, warningSent: Bool = true) -> MemoryOptimizer.Phase {
    .finished(MemoryOptimization(freed: freed, usedBefore: 10 * gigabyte, usedAfter: 9 * gigabyte,
                                 report: MemoryReclaimReport(diskCacheFlushed: cacheFlushed, pressureWarningSent: warningSent),
                                 date: .now))
}

struct OptimizationMessageTests {
    @Test func beforeAndDuringTheRunItSaysWhatItDoes() {
        let idle = OptimizationMessage(.idle, total: total)
        #expect(idle.tone == .about && idle.detail == nil)
        #expect(idle.title.contains("No app is closed"))
        // The helper question is on screen; the line under the button stays as it was.
        #expect(OptimizationMessage(.asking, total: total) == idle)
        let running = OptimizationMessage(.running, total: total)
        #expect(running.tone == .working)
        #expect(running.title == "Freeing memory…")
    }

    @Test func aNoticeableGrowthIsReportedWithTheMeasuredUse() {
        let message = OptimizationMessage(finished(freed: 2 * gigabyte), total: total)
        #expect(message.tone == .freed)
        #expect(message.title == "\(Format.memory(2 * gigabyte)) freed")
        #expect(message.detail == "Memory used: \(Format.memory(10 * gigabyte)) → \(Format.memory(9 * gigabyte))")
    }

    @Test func growthWithinTheNoiseIsNothingFreed() {
        let threshold = OptimizationMessage.noticeable(total: total)
        #expect(threshold == total / 100)
        #expect(OptimizationMessage(finished(freed: threshold), total: total).tone == .freed)
        for freed in [threshold - 1, 20 << 20, 0] {
            let message = OptimizationMessage(finished(freed: freed), total: total)
            #expect(message.tone == .nothingFreed, "\(freed)")
            #expect(message.title == "Nothing to free right now")
            // What was measured is still shown.
            #expect(message.detail?.hasPrefix("Memory used:") == true)
        }
        // The threshold grows with the Mac's memory.
        #expect(OptimizationMessage(finished(freed: threshold), total: 64 * gigabyte).tone == .nothingFreed)
    }

    @Test func partWorkSaysWhichStepFailed() {
        let noWarning = OptimizationMessage(finished(freed: gigabyte, warningSent: false), total: total)
        #expect(noWarning.tone == .partial)
        #expect(noWarning.title == "Done in part: \(Format.memory(gigabyte)) freed")
        #expect(noWarning.detail == "Apps couldn’t be asked to return memory.")

        let noCacheFlush = OptimizationMessage(finished(freed: 0, cacheFlushed: false), total: total)
        #expect(noCacheFlush.tone == .partial)
        #expect(noCacheFlush.title == "Done in part: nothing freed")
        #expect(noCacheFlush.detail == "The disk cache couldn’t be cleared.")
    }

    @Test func aFailureShowsItsMessage() {
        let message = OptimizationMessage(.failed("Memory couldn’t be freed. Try again in a moment."), total: total)
        #expect(message == OptimizationMessage(.failed("Memory couldn’t be freed. Try again in a moment."), total: total))
        #expect(message.tone == .failed)
        #expect(message.title == "Memory couldn’t be freed. Try again in a moment.")
        #expect(message.detail == nil)
    }
}
