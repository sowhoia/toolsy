import Foundation
import Testing
import ToolsyEngine
import ToolsyShared
@testable import Toolsy

struct DiagnosticsTests {
    private let facts = Diagnostics.Facts(
        toolsyVersion: "1.1.0", build: "2", system: "macOS 26.5 (25F71)", model: "MacBook Air", chip: "Apple M4",
        architecture: "arm64", helper: .ready, developerMode: false,
        mods: [
            .init(id: "keep-awake", version: "1.2", isOn: true, access: .notNeeded, runs: [
                .init(command: "status", cause: .refresh, duration: .milliseconds(45), outcome: .succeeded),
                .init(command: "service", cause: .service, duration: .zero, outcome: .started),
                .init(command: "apply", cause: .command, duration: .seconds(30), outcome: .timedOut),
            ]),
            .init(id: "guard", version: "2", isOn: nil, access: .notApproved(modified: true), runs: []),
        ],
        loadProblems: [.init(folder: "broken", message: #"/Users/someone/Library/Application Support/Toolsy/Mods/broken/mod.json: missing required field "id""#)],
        widgets: ["cpu", "memory", "mod:keep-awake/awake"]
    )

    /// For a bug report: what Toolsy, the Mac and the mods are and what the mods did, never what they printed,
    /// and no path that names the user's account.
    @Test func saysWhatToolsyTheMacAndTheModsAreAndDid() {
        let report = Diagnostics.report(facts, home: "/Users/someone")
        #expect(report.hasPrefix("Toolsy 1.1.0 (2)\nmacOS 26.5 (25F71)\nMacBook Air, Apple M4, arm64\nAdministrator helper: ready\nDeveloper mode: off\n"))
        #expect(report.contains("\nkeep-awake 1.2: on, no administrator commands\n  status on refresh: succeeded, "))
        #expect(report.contains("\n  service on service: service started\n"))
        #expect(report.contains("\n  apply on command: timed out, "))
        #expect(report.contains("\nguard 2: no switch, administrator commands, files changed since installing\n  no runs\n"))
        #expect(report.contains("\nbroken: ~/Library/Application Support/Toolsy/Mods/broken/mod.json: missing required field \"id\"\n"))
        #expect(report.hasSuffix("\nDashboard: cpu, memory, mod:keep-awake/awake\n"))
        #expect(!report.contains("someone"))
    }
}
