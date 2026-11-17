import AppKit
import Testing
import ToolsyShared
@testable import Toolsy

/// What VoiceOver is told about changes that appear where its focus is not.
@MainActor
struct AnnouncementTests {
    @Test func aDialogIsAnnouncedByItsTitle() {
        var said: [String] = []
        let panel = PanelState(announce: { said.append($0) })
        panel.confirm(ConfirmationRequest(title: "Quit “Notes”?", message: "“Notes” may ask you to save changes first.",
                                          confirmTitle: "Quit"))
        #expect(said == ["Quit “Notes”?"])
        // One that replaces it is announced as well; closing one is not.
        panel.confirm(ConfirmationRequest(title: "Setting up Toolsy’s helper…", confirmTitle: "", isProgress: true))
        panel.dismissProgress()
        #expect(said == ["Quit “Notes”?", "Setting up Toolsy’s helper…"])
    }

    @Test func aCopyIsAnnounced() throws {
        // A pasteboard of the test's own: the general one belongs to whoever uses this Mac.
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("app.toolsy.tests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        var said: [String] = []
        let feedback = CopyFeedback(pasteboard: pasteboard, announce: { said.append($0) })
        feedback.copy("192.168.1.2")
        #expect(pasteboard.string(forType: .string) == "192.168.1.2")
        #expect(feedback.isShowing)
        #expect(said == ["Copied"])
    }

    /// The result of freeing memory is said in full when it arrives; before and during the run, nothing is.
    @Test func aMemoryResultIsAnnouncedInFull() throws {
        let gigabyte: UInt64 = 1 << 30
        let result = MemoryOptimization(usedBefore: 10 * gigabyte, usedAfter: 8 * gigabyte, cachedBefore: 5 * gigabyte,
                                        cachedAfter: gigabyte,
                                        report: MemoryReclaimReport(diskCacheFlushed: true, pressureWarningSent: true), date: .now)
        let finished = OptimizationMessage(.finished(result), total: 16 * gigabyte)
        let detail = try #require(finished.detail)
        #expect(finished.announcement == "\(finished.title)\n\(detail)")
        let failed = OptimizationMessage(.failed("Memory couldn’t be freed. Try again in a moment."), total: 16 * gigabyte)
        #expect(failed.announcement == "Memory couldn’t be freed. Try again in a moment.")
        for phase in [MemoryOptimizer.Phase.idle, .asking, .running] {
            #expect(OptimizationMessage(phase, total: 16 * gigabyte).announcement == nil, "\(phase)")
        }
    }
}
