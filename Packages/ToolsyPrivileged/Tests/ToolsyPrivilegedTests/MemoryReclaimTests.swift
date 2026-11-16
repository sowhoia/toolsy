import Foundation
import Testing
@testable import ToolsyHelperClient
@testable import ToolsyHelperCore
import ToolsyHelperXPC
import ToolsyShared

/// Harmless stand-ins for `purge` and `memory_pressure` that record how they were started.
private struct StandInTools {
    let directory: TemporaryDirectory
    let tools: MemoryTools
    private var log: URL { directory.path("bin/calls.log") }

    /// One script for every test, linked into each test's folder under the name of the tool it stands
    /// in for. macOS checks a new executable on its first start, which takes long enough to break the
    /// short timeouts below and to slow down every other test; a hard link is not new. The script stays
    /// in the temporary folder between runs and is rewritten only when its text changes.
    private static let script = Task {
        // Records the call, then runs the behaviour the test chose for this step from the link's folder.
        let text = """
            #!/bin/sh
            [ "$1" = warm-up ] && exit 0
            folder=${0%/*}
            tool=${0##*/}
            printf '%s %s\\n' "$tool" "$*" >> "$folder/calls.log"
            /usr/bin/env > "$folder/$tool.env"
            /bin/pwd -P > "$folder/$tool.pwd"
            case $tool in purge) step=purge ;; *) step=$3 ;; esac
            . "$folder/$step.sh"

            """
        let script = URL.temporaryDirectory.appending(path: "toolsy-privileged-memory-stand-in")
        if (try? Data(contentsOf: script)) != Data(text.utf8) {
            try Data(text.utf8).write(to: script, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path(percentEncoded: false))
        }
        _ = try await ProcessRunner.run(ProcessRunner.Request(executable: script, arguments: ["warm-up"]))
        return script
    }

    /// Each body is shell code run after the call was recorded; for `memory_pressure`, `warn` and
    /// `normal` are chosen by the level argument.
    init(purge: String = "exit 0", warn: String = "exit 0", normal: String = "exit 0",
         purgeTimeout: TimeInterval = 10, pressureTimeout: TimeInterval = 10) async throws {
        directory = try TemporaryDirectory()
        let script = try await Self.script.value
        for (step, body) in [("purge", purge), ("warn", warn), ("normal", normal)] {
            try directory.write(body + "\n", to: "bin/\(step).sh")
        }
        let purgeTool = directory.path("bin/purge"), pressureTool = directory.path("bin/memory_pressure")
        for tool in [purgeTool, pressureTool] {
            try FileManager.default.linkItem(at: script, to: tool)
        }
        tools = MemoryTools(purge: purgeTool, memoryPressure: pressureTool, purgeTimeout: purgeTimeout,
                            pressureTimeout: pressureTimeout, restoreTimeout: 10)
    }

    var calls: [String] {
        guard let data = try? Data(contentsOf: log) else { return [] }
        return text(data).split(separator: "\n").map(String.init)
    }

    /// The environment the tool was started with. `sh` itself adds PWD, SHLVL and `_`.
    func environment(of tool: URL) throws -> [String: String] {
        var variables = keyValues(try Data(contentsOf: URL(filePath: tool.path(percentEncoded: false) + ".env")))
        for added in ["PWD", "SHLVL", "_"] { variables[added] = nil }
        return variables
    }

    func workingDirectory(of tool: URL) throws -> String {
        text(try Data(contentsOf: URL(filePath: tool.path(percentEncoded: false) + ".pwd")))
            .trimmingCharacters(in: .newlines)
    }

    func service() throws -> HelperService {
        HelperService(store: try makeStore(in: directory), installedFiles: [], memoryTools: tools)
    }
}

private let warn = "memory_pressure -S -l warn -s 3"
private let backToNormal = "memory_pressure -S -l normal -s 0"

@Suite struct MemoryReclaimTests {
    @Test func theProductionStepsAreTheSystemTools() {
        #expect(MemoryTools.production.purge.path(percentEncoded: false) == "/usr/sbin/purge")
        #expect(MemoryTools.production.memoryPressure.path(percentEncoded: false) == "/usr/bin/memory_pressure")
    }

    @Test func runsTheFixedStepsInOrderWithAFixedEnvironment() async throws {
        let standIns = try await StandInTools()
        let report = try await standIns.service().reclaimMemory()
        #expect(report == MemoryReclaimReport(diskCacheFlushed: true, pressureWarningSent: true))
        // A warning that ran to its end set the level back itself: no extra step.
        #expect(standIns.calls == ["purge ", warn])
        for tool in [standIns.tools.purge, standIns.tools.memoryPressure] {
            #expect(try standIns.environment(of: tool) == ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"])
            #expect(try standIns.workingDirectory(of: tool) == "/")
        }
    }

    @Test func aFailingStepDoesNotStopTheNext() async throws {
        let standIns = try await StandInTools(purge: "exit 1")
        let report = try await standIns.service().reclaimMemory()
        #expect(report == MemoryReclaimReport(diskCacheFlushed: false, pressureWarningSent: true))
        #expect(standIns.calls == ["purge ", warn])
    }

    @Test func aFailedWarningIsFollowedByTheWayBackToNormal() async throws {
        let standIns = try await StandInTools(warn: "exit 255")
        let report = try await standIns.service().reclaimMemory()
        #expect(report == MemoryReclaimReport(diskCacheFlushed: true, pressureWarningSent: false))
        #expect(standIns.calls == ["purge ", warn, backToNormal])
    }

    @Test func aWarningCutShortByItsTimeoutEndsAtNormal() async throws {
        let standIns = try await StandInTools(warn: "sleep 30", pressureTimeout: 0.5)
        let started = ContinuousClock.now
        let report = try await standIns.service().reclaimMemory()
        #expect(ContinuousClock.now - started < .seconds(5))
        #expect(report == MemoryReclaimReport(diskCacheFlushed: true, pressureWarningSent: false))
        #expect(standIns.calls == ["purge ", warn, backToNormal])
    }

    @Test func aPurgeCutShortByItsTimeoutStillLetsTheWarningRun() async throws {
        let standIns = try await StandInTools(purge: "sleep 30", purgeTimeout: 0.5)
        let report = try await standIns.service().reclaimMemory()
        #expect(report == MemoryReclaimReport(diskCacheFlushed: false, pressureWarningSent: true))
        #expect(standIns.calls == ["purge ", warn])
    }

    @Test func aToolThatCannotStartIsAFailedStep() async throws {
        let standIns = try await StandInTools()
        var tools = standIns.tools
        tools.purge = standIns.directory.path("bin/missing")
        let service = HelperService(store: try makeStore(in: standIns.directory), installedFiles: [], memoryTools: tools)
        let report = try await service.reclaimMemory()
        #expect(report == MemoryReclaimReport(diskCacheFlushed: false, pressureWarningSent: true))
        #expect(standIns.calls == [warn])
    }

    @Test func oneReclaimAtATime() async throws {
        let standIns = try await StandInTools(warn: "sleep 1")
        let service = try standIns.service()
        let first = Task { try await service.reclaimMemory() }
        #expect(try await eventually { standIns.calls.contains(warn) })
        await #expect(throws: HelperError.reclaimingMemory) { try await service.reclaimMemory() }
        #expect(try await first.value.isComplete)
        // Refused, not queued: it never ran.
        #expect(standIns.calls == ["purge ", warn])
        #expect(try await service.reclaimMemory().isComplete)
    }

    // MARK: Over XPC

    @Test func roundTripsAndTakesNothingFromTheClient() async throws {
        let standIns = try await StandInTools(purge: "exit 1")
        let helper = try InProcessHelper(clientRequirement: try ownRequirement(), memoryTools: standIns.tools)
        let report = try await helper.client().reclaimMemory()
        #expect(report == MemoryReclaimReport(diskCacheFlushed: false, pressureWarningSent: true))
        // The request carries no parameters; what ran is exactly the fixed list.
        #expect(standIns.calls == ["purge ", warn])
    }

    @Test func aRunningReclaimIsNotInterrupted() async throws {
        // A short idle interval: the helper would exit during the reclaim if the reclaim did not count.
        let standIns = try await StandInTools(warn: "sleep 1")
        let helper = try InProcessHelper(clientRequirement: try ownRequirement(), idleInterval: 0.3, memoryTools: standIns.tools)
        let client = helper.client()
        let running = Task { try await client.reclaimMemory() }
        #expect(try await eventually { standIns.calls.contains(warn) })

        let asked = ContinuousClock.now
        await #expect(throws: PrivilegedError.busy) { try await client.reclaimMemory() }
        await #expect(throws: PrivilegedError.busy) { try await client.uninstall() }
        #expect(ContinuousClock.now - asked < .milliseconds(700))

        // The client giving up does not stop it either.
        running.cancel()
        await #expect(throws: CancellationError.self) { try await running.value }
        try await Task.sleep(for: .milliseconds(600))
        #expect(helper.exited.withLock { $0 } == 0)
        #expect(FileManager.default.fileExists(atPath: helper.store.root.path(percentEncoded: false)))
        // Once it is done and nobody is connected, the helper goes idle as usual.
        #expect(try await eventually { helper.exited.withLock { $0 } == 1 })
        #expect(standIns.calls == ["purge ", warn])
    }

    @Test func aHelperThatStopsAnsweringDoesNotHangTheClient() async throws {
        let fake = try FakeHelper(SilentHelper())
        var timeouts = HelperClient.Timeouts.short
        timeouts.reclaimMemory = .milliseconds(500)
        await #expect(throws: PrivilegedError.helperUnavailable(.needsUpdate)) {
            try await fake.client(timeouts: timeouts).reclaimMemory()
        }
    }
}
