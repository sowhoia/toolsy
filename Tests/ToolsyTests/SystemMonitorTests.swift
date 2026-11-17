import Foundation
import Testing
@testable import Toolsy

@MainActor
private func waitUntil(_ what: String, _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while !condition() {
        guard ContinuousClock.now < deadline else {
            Issue.record("timed out waiting for \(what)")
            throw CancellationError()
        }
        try await Task.sleep(for: .milliseconds(20))
    }
}

/// Samples the real Mac: the first sample comes a quarter of a second after sampling starts.
@MainActor
struct SystemMonitorTests {
    private func histories(_ monitor: SystemMonitor) -> [[Double]] {
        [monitor.cpuHistory, monitor.downloadHistory, monitor.uploadHistory, monitor.gpuHistory,
         monitor.diskReadHistory, monitor.diskWriteHistory].map(\.values)
    }

    /// A chart shows one stretch of time: what an earlier opening sampled is not drawn as if it ran on into
    /// the new samples.
    @Test func eachOpeningStartsTheChartsAfresh() async throws {
        let monitor = SystemMonitor()
        monitor.shownMetrics = monitor.availableMetrics.intersection([.cpu, .network, .gpu, .disk])
        monitor.start()
        defer { monitor.stop() }
        try await waitUntil("the first samples") { monitor.cpuHistory.values.count == 1 && monitor.downloadHistory.values.count == 1 }
        monitor.stop()
        let reading = monitor.cpu
        #expect(reading != nil)

        monitor.start()
        #expect(histories(monitor) == Array(repeating: [], count: 6))
        #expect(monitor.cpu == reading, "the last reading stays until a new one replaces it")
        try await waitUntil("a new sample") { monitor.cpuHistory.values.count == 1 }
    }

    /// A widget put back on the dashboard while the panel is open does not continue the chart it had before.
    @Test func aMetricShownAgainStartsAfresh() async throws {
        let monitor = SystemMonitor()
        monitor.shownMetrics = [.cpu, .network]
        monitor.start()
        defer { monitor.stop() }
        try await waitUntil("the first samples") { monitor.downloadHistory.values.count == 1 }
        monitor.shownMetrics = [.cpu]
        try await waitUntil("a sample without the network") { monitor.cpuHistory.values.count == 2 }
        #expect(monitor.downloadHistory.values.count == 1, "a metric that is not shown is not sampled")

        monitor.shownMetrics = [.cpu, .network]
        #expect(monitor.downloadHistory.values.isEmpty && monitor.uploadHistory.values.isEmpty)
        #expect(monitor.cpuHistory.values.count == 2, "the metrics that stayed keep their charts")
    }
}
