import Testing
import ToolsyShared

@Suite struct SystemMaintenanceTests {
    @Test func aReportTellsCompleteFromPartialFromNothing() {
        let complete = MemoryReclaimReport(diskCacheFlushed: true, pressureWarningSent: true)
        #expect(complete.isComplete && complete.didAnything)
        for partial in [MemoryReclaimReport(diskCacheFlushed: true, pressureWarningSent: false),
                        MemoryReclaimReport(diskCacheFlushed: false, pressureWarningSent: true)] {
            #expect(!partial.isComplete && partial.didAnything)
        }
        let nothing = MemoryReclaimReport(diskCacheFlushed: false, pressureWarningSent: false)
        #expect(!nothing.isComplete && !nothing.didAnything)
    }
}
