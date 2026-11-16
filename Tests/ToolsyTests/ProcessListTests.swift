import Foundation
import Testing
@testable import Toolsy

private func group(_ id: String, memory: UInt64 = 0, cpu: Double = 0, processes: Int = 1, canQuit: Bool = false) -> ProcessGroup {
    ProcessGroup(id: id, name: id, icon: nil, memory: memory, cpu: cpu, processCount: processes, canQuit: canQuit,
                 applicationPID: canQuit ? 1 : nil)
}

private let megabyte: UInt64 = 1 << 20

private func order(_ top: [ProcessGroup], after previous: [String], by measure: ProcessMeasure = .memory) -> [String] {
    ProcessRow.order(top, previous: previous, by: measure).map(\.id)
}

struct ProcessRowTests {
    @Test func valuesAreFormattedAsActivityMonitorShowsThem() {
        #expect(ProcessRow(group("a", memory: 1536 * megabyte), measure: .memory).value == Format.memory(1536 * megabyte))
        // 100 % is one core; a decimal only below 10 %.
        let digits = { (cpu: Double) in ProcessRow(group("a", cpu: cpu), measure: .cpu).value.filter(\.isNumber) }
        #expect(digits(153.4) == "153")
        #expect(digits(12.6) == "13")
        #expect(digits(4.4) == "44")
        #expect(digits(0) == "00")
    }

    @Test func severalProcessesAreCountedDiscreetly() {
        #expect(ProcessRow(group("a", processes: 1), measure: .memory).processCount == nil)
        #expect(ProcessRow(group("a", processes: 12), measure: .memory).processCount == "×12")
    }

    @Test func onlyAppsThatCanBeAskedToQuitOfferItAndOnlyInTheMemoryList() {
        #expect(ProcessRow(group("a", canQuit: true), measure: .memory).offersQuit)
        #expect(!ProcessRow(group("a", canQuit: false), measure: .memory).offersQuit)
        #expect(!ProcessRow(group("a", canQuit: true), measure: .cpu).offersQuit)
    }
}

struct ProcessOrderTests {
    @Test func aFirstListFollowsTheData() {
        let top = [group("a", memory: 500 * megabyte), group("b", memory: 300 * megabyte), group("c", memory: 100 * megabyte)]
        #expect(order(top, after: []) == ["a", "b", "c"])
    }

    @Test func rowsKeepTheirPlacesUntilTheDifferenceIsNoticeable() {
        // b was shown above a; a now has 3 % more: noise.
        #expect(order([group("a", memory: 1030 * megabyte), group("b", memory: 1000 * megabyte)], after: ["b", "a"]) == ["b", "a"])
        // 20 % more: a moves up.
        #expect(order([group("a", memory: 1200 * megabyte), group("b", memory: 1000 * megabyte)], after: ["b", "a"]) == ["a", "b"])
    }

    @Test func newRowsRiseAsFarAsTheyHaveMoreAndGoneRowsLeave() {
        let top = [group("new", memory: 4000 * megabyte), group("a", memory: 900 * megabyte), group("b", memory: 800 * megabyte),
                   group("small", memory: 100 * megabyte)]
        #expect(order(top, after: ["gone", "a", "b"]) == ["new", "a", "b", "small"])
        // A row far below its old place sinks past several rows at once.
        let shrunk = [group("b", memory: 900 * megabyte), group("c", memory: 800 * megabyte), group("a", memory: 10 * megabyte)]
        #expect(order(shrunk, after: ["a", "b", "c"]) == ["b", "c", "a"])
    }

    @Test func cpuNeedsAFewPercentOfACoreToReorder() {
        // Light use jumps by fractions of a percent from sample to sample.
        #expect(order([group("b", cpu: 2.5), group("a", cpu: 1)], after: ["a", "b"], by: .cpu) == ["a", "b"])
        #expect(order([group("b", cpu: 4), group("a", cpu: 1)], after: ["a", "b"], by: .cpu) == ["b", "a"])
        // Heavier use needs a quarter more.
        #expect(order([group("b", cpu: 120), group("a", cpu: 100)], after: ["a", "b"], by: .cpu) == ["a", "b"])
        #expect(order([group("b", cpu: 130), group("a", cpu: 100)], after: ["a", "b"], by: .cpu) == ["b", "a"])
    }
}
