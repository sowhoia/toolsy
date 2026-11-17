import AppKit
import Foundation
import Testing
@testable import Toolsy

private func waitUntil(_ what: String, _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while !condition() {
        guard ContinuousClock.now < deadline else {
            Issue.record("timed out waiting for \(what)")
            throw CancellationError()
        }
        try await Task.sleep(for: .milliseconds(50))
    }
}

@MainActor
struct ProcessMonitorIconTests {
    /// An app's icon is read once while it runs: a new image every sample read the file system each time
    /// and made every row of the lists draw its icon again.
    @Test func iconsAreTheSameImagesFromSampleToSample() async throws {
        let panel = PanelState()
        panel.setVisible(true)
        let monitor = ProcessMonitor(panel: panel, interval: 0.2)
        monitor.start(for: .memory)
        defer { monitor.stop(for: .memory) }
        try await waitUntil("the first groups") { !monitor.groups.isEmpty }
        let firstSample = monitor.groups
        // Every sample measures CPU anew, so the next one differs.
        try await waitUntil("the next sample") { monitor.groups != firstSample }
        let first = Dictionary(uniqueKeysWithValues: firstSample.map { ($0.id, $0) })
        // Finder runs in every session and is a registered application inside a bundle.
        let apps = monitor.groups.filter { $0.applicationPID != nil && first[$0.id]?.icon != nil }
        #expect(apps.contains { $0.id.hasSuffix("/Finder.app") })
        for app in apps {
            #expect(app.icon === first[app.id]?.icon, "\(app.name)")
        }
    }
}
