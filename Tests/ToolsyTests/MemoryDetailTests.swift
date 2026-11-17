import Foundation
import Testing
import ToolsyShared
@testable import Toolsy

private let gigabyte: UInt64 = 1 << 30
private let total = 16 * gigabyte

/// Memory used falls by `freed` from 10 GB; the file cache falls from 5 GB to 1 GB.
private func finished(freed: UInt64, cacheFlushed: Bool = true, warningSent: Bool = true) -> MemoryOptimizer.Phase {
    .finished(MemoryOptimization(usedBefore: 10 * gigabyte, usedAfter: 10 * gigabyte - freed,
                                 cachedBefore: 5 * gigabyte, cachedAfter: gigabyte,
                                 report: MemoryReclaimReport(diskCacheFlushed: cacheFlushed, pressureWarningSent: warningSent),
                                 date: .now))
}

private let usedLine = { (freed: UInt64) in "Memory used: \(Format.memory(10 * gigabyte)) → \(Format.memory(10 * gigabyte - freed))" }
private let cacheLine = "Cached files: \(Format.memory(5 * gigabyte)) → \(Format.memory(gigabyte))"

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

    /// What apps gave back is the headline; the file cache that was cleared is stated apart, measured too.
    @Test func aNoticeableFallOfMemoryUsedIsReportedWithTheMeasurements() {
        let message = OptimizationMessage(finished(freed: 2 * gigabyte), total: total)
        #expect(message.tone == .freed)
        #expect(message.title == "\(Format.memory(2 * gigabyte)) freed")
        #expect(message.detail == usedLine(2 * gigabyte) + "\n" + cacheLine)
    }

    @Test func aFallWithinTheNoiseIsNothingFreed() {
        let threshold = OptimizationMessage.noticeable(total: total)
        #expect(threshold == total / 100)
        #expect(OptimizationMessage(finished(freed: threshold), total: total).tone == .freed)
        for freed in [threshold - 1, 20 << 20, 0] {
            let message = OptimizationMessage(finished(freed: freed), total: total)
            #expect(message.tone == .nothingFreed, "\(freed)")
            #expect(message.title == "Nothing to free right now")
            // What was measured is still shown, the 4 GB of cleared cache among it: not called freed.
            #expect(message.detail == usedLine(freed) + "\n" + cacheLine)
        }
        // The threshold grows with the Mac's memory.
        #expect(OptimizationMessage(finished(freed: threshold), total: 64 * gigabyte).tone == .nothingFreed)
    }

    @Test func partWorkSaysWhichStepFailed() {
        let noWarning = OptimizationMessage(finished(freed: gigabyte, warningSent: false), total: total)
        #expect(noWarning.tone == .partial)
        #expect(noWarning.title == "Done in part: \(Format.memory(gigabyte)) freed")
        #expect(noWarning.detail == "Apps couldn’t be asked to return memory.\n" + cacheLine)

        // The cache was not flushed: how it changed meanwhile is not the optimisation's doing.
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
