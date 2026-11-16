import Foundation
import Testing
@testable import ToolsyEngine
import ToolsyShared

/// A mod whose service is `svc.sh`, sourced by `/bin/sh` so it starts without the first-launch scan
/// macOS gives a freshly written executable; `disable` logs.
private func serviceMod(settings: String = "{}", stdin: Bool = false, chart: Bool = false, enableHook: Bool = false) -> String {
    manifest(#"""
        "settings": \#(settings),
        "commands": {"watch": {"shell": ". ./svc.sh", "stdin": \#(stdin)}, "off": {"shell": ". ./off.sh"}, "on": {"shell": ". ./on.sh"}},
        "lifecycle": {"service": "watch", "disable": "off"\#(enableHook ? #", "enable": "on""# : "")},
        "ui": [\#(chart ? #"{"type": "chart", "series": [{"bind": "ms"}], "points": 5}"# : "")]
        """#)
}

/// Logs "disable", or "disable while the service runs" when the service that reported `pid` is still alive.
private let offScript = logLine + #"; if kill -0 "$TOOLSY_STATE_pid" 2>/dev/null; then log disable while the service runs; else log disable; fi"#
private let onScript = logLine + "; log enable"

@MainActor @Suite struct ServiceTests {
    @Test func appliesEachLineAsAPatch() async throws {
        try await withHarness { harness in
            let mod = try await harness.install(serviceMod(stdin: true, chart: true), scripts: [
                "off.sh": offScript,
                "svc.sh": #"""
                    read -r input; printf '%s' "$input" > "$TOOLSY_DATA_DIR/input.json"
                    echo "{\"event\": \"$TOOLSY_EVENT\"}"
                    head -c 300000 /dev/zero | tr '\0' 'a'; echo
                    echo 'not a patch'
                    printf '{"long": "survived"}\n'
                    i=0; while :; do i=$((i+1)); echo "{\"ms\": $i, \"status\": \"tick $i\"}"; sleep 0.02; done
                    """#,
            ])
            await mod.setEnabled(true)
            #expect(mod.isEnabled)
            try await eventually("ticks") { (mod.state["ms"]?.numberValue ?? 0) >= 7 }
            #expect(mod.state["event"] == "service" && mod.state["long"] == "survived")
            let history = mod.history(of: "ms")
            #expect(history.count == 5 && zip(history, history.dropFirst()).allSatisfy { $1 == $0 + 1 })
            let input = try JSONDecoder().decode(CommandInput.self, from: Data(contentsOf: harness.directories.data.appending(path: "demo/input.json")))
            #expect(input.event == .service && input.command == "watch" && input.state["enabled"] == true)

            await mod.setEnabled(false)
            let last = mod.state["ms"]
            try await Task.sleep(for: .milliseconds(100))
            #expect(mod.state["ms"] == last, "a stopped service reports nothing")
            #expect(harness.log() == ["disable"])
        }
    }

    @Test func restartsWhenASettingChanges() async throws {
        try await withHarness { harness in
            let mod = try await harness.install(serviceMod(settings: #"{"host": "a"}"#), scripts: [
                "off.sh": offScript,
                "svc.sh": logLine + #"; log "start $TOOLSY_STATE_host"; echo "{\"seen\": \"$TOOLSY_STATE_host\", \"pid\": $$}"; exec sleep 30"#,
            ])
            await mod.setEnabled(true)
            try await eventually("first start") { mod.state["seen"] == "a" }
            let firstPID = try #require(mod.state["pid"]?.numberValue).asPID
            mod.setValue("b", for: "host")
            mod.setValue("c", for: "host")
            try await eventually("restart with the new value") { mod.state["seen"] == "c" }
            #expect(harness.log() == ["start a", "start c"], "changes within the debounce restart once")
            try await eventually("the old process is gone") { !isAlive(firstPID) }
            mod.setValue("live only", for: "notASetting")
            mod.setValue("c", for: "host")
            try await Task.sleep(for: .milliseconds(100))
            #expect(harness.log().count == 2, "neither live state nor an unchanged setting restarts the service")
        }
    }

    @Test func aRefreshReportingTheModOnStartsTheService() async throws {
        try await withHarness { harness in
            let mod = try await harness.install(manifest(#"""
                "commands": {"watch": {"shell": "echo '{\"serving\": true}'; exec sleep 30"}, "check": {"shell": "echo '{\"enabled\": true}'"}},
                "lifecycle": {"service": "watch", "refresh": {"command": "check"}}
                """#))
            harness.store.isPanelVisible = true
            try await eventually("the service runs") { mod.state["serving"] == true }
            #expect(mod.isEnabled && !mod.isSwitching)
        }
    }

    @Test func exitZeroSwitchesTheModOff() async throws {
        try await withHarness { harness in
            let mod = try await harness.install(serviceMod(), scripts: [
                "off.sh": offScript, "svc.sh": #"echo '{"status": "done"}'; exit 0"#,
            ])
            await mod.setEnabled(true)
            try await eventually("switched off") { !mod.isEnabled && !mod.isSwitching }
            #expect(mod.status == "done" && mod.error == nil)
            #expect(harness.log() == ["disable"])
            let saved = try JSONDecoder().decode(PersistedState.self, from: Data(contentsOf: harness.directories.state.appending(path: "demo.json")))
            #expect(!saved.enabled)
        }
    }

    /// Crashes on its first four starts unless `healthyRun` names a start that runs 0.5 s before crashing;
    /// from the fifth start on it stays up.
    private func crashingService(healthyRun: Int = 0) -> String {
        #"""
        n=$(cat "$TOOLSY_DATA_DIR/count" 2>/dev/null || echo 0); n=$((n+1)); echo $n > "$TOOLSY_DATA_DIR/count"
        if [ $n -ge 5 ]; then echo '{"status": "stable"}'; exec sleep 30; fi
        if [ $n -eq \#(healthyRun) ]; then sleep 0.5; fi
        echo "crash $n" >&2; exit 3
        """#
    }

    @Test func restartsACrashedServiceWithBackoff() async throws {
        try await withHarness { harness in
            let mod = try await harness.install(serviceMod(), scripts: ["off.sh": offScript, "svc.sh": crashingService()])
            await mod.setEnabled(true)
            try await eventually("the crash is shown") { mod.error?.hasPrefix("crash ") == true }
            try await eventually("stable after four crashes") { mod.status == "stable" }
            #expect(mod.restartDelays == [1, 2, 4, 8])
            #expect(mod.error == nil && mod.isEnabled, "the service reporting again clears the error it raised")
        }
    }

    @Test func aHealthyRunResetsTheBackoff() async throws {
        // Scale 0.01: healthy after 0.3 s; the third start runs 0.5 s.
        try await withHarness { harness in
            let mod = try await harness.install(serviceMod(), scripts: ["off.sh": offScript, "svc.sh": crashingService(healthyRun: 3)])
            await mod.setEnabled(true)
            try await eventually("stable after four crashes") { mod.status == "stable" }
            #expect(mod.restartDelays == [1, 2, 1, 2])
        }
    }

    @Test func killsWhatACrashedServiceLeftRunning() async throws {
        try await withHarness { harness in
            let mod = try await harness.install(serviceMod(), scripts: [
                "off.sh": offScript, "svc.sh": #"sleep 30 & echo "{\"child\": $!}"; exit 1"#,
            ])
            await mod.setEnabled(true)
            try await eventually("the child is reported") { mod.state["child"] != nil }
            let child = try #require(mod.state["child"]?.numberValue).asPID
            try await eventually("the child is killed", timeout: .seconds(3)) { !isAlive(child) }
            await mod.setEnabled(false)
        }
    }

    @Test func stopsOnShutdownWithoutDisableAndRestoresOnLaunch() async throws {
        try await withHarness { harness in
            let mod = try await harness.install(serviceMod(enableHook: true), scripts: [
                "off.sh": offScript, "on.sh": onScript,
                "svc.sh": logLine + #"; log service; sleep 30 & echo "{\"child\": $!, \"pid\": $$}"; wait"#,
            ])
            await mod.setEnabled(true)
            try await eventually("running") { mod.state["child"] != nil }
            let child = try #require(mod.state["child"]?.numberValue).asPID
            let service = try #require(mod.state["pid"]?.numberValue).asPID

            await harness.relaunch()
            #expect(!isAlive(child) && !isAlive(service), "shutdown leaves no processes behind")
            #expect(harness.log() == ["enable", "service"], "shutdown does not run disable")

            let restored = try harness.mod()
            #expect(restored.isEnabled)
            try await eventually("restored") { restored.state["child"] != nil }
            #expect(harness.log() == ["enable", "service", "service"], "a relaunch starts the service without enable")
            let restoredChild = try #require(restored.state["child"]?.numberValue).asPID
            await harness.store.shutdown()
            #expect(!isAlive(restoredChild))
        }
    }

    @Test func killsAServiceThatIgnoresTerm() async throws {
        try await withHarness { harness in
            let mod = try await harness.install(serviceMod(), scripts: [
                "off.sh": offScript,
                "svc.sh": #"trap '' TERM; sleep 30 & echo "{\"pid\": $$, \"child\": $!}"; while :; do sleep 0.05; done"#,
            ])
            await mod.setEnabled(true)
            try await eventually("running") { mod.state["pid"] != nil }
            let service = try #require(mod.state["pid"]?.numberValue).asPID
            let child = try #require(mod.state["child"]?.numberValue).asPID
            await mod.setEnabled(false)
            #expect(!isAlive(service) && !isAlive(child))
            #expect(harness.log() == ["disable"], "the service is gone before disable runs")
        }
    }
}

/// What a later launch does about services whose Toolsy died without stopping them.
@MainActor @Suite struct ServiceSurvivorTests {
    /// A process group like a service's, started outside any store: a shell and a child of it.
    private func startStray() throws -> Process {
        let stray = Process()
        stray.executableURL = URL(filePath: "/bin/sh")
        stray.arguments = ["-c", "sleep 300 & wait"]
        try stray.run()
        return stray
    }

    private func recordFile(_ harness: Harness) -> URL {
        harness.directories.root.appending(path: "Run/demo.json")
    }

    @Test func recordsTheRunningServiceAndForgetsItWhenStopped() async throws {
        try await withHarness { harness in
            let mod = try await harness.install(manifest(#"""
                "commands": {"watch": {"shell": "echo \"{\\\"pid\\\": $$}\"; exec sleep 300"}},
                "lifecycle": {"service": "watch"}
                """#))
            await mod.setEnabled(true)
            try await eventually("running") { mod.state["pid"] != nil }
            let record = try JSONDecoder().decode(ServiceRecord.self, from: Data(contentsOf: recordFile(harness)))
            #expect(record.pid == mod.state["pid"]?.numberValue.map { Int32($0) } && record.isRunning)

            await mod.setEnabled(false)
            #expect(!FileManager.default.fileExists(atPath: recordFile(harness).path(percentEncoded: false)))
            #expect(!record.isRunning)
        }
    }

    @Test func stopsAServiceThatOutlivedItsToolsy() async throws {
        let harness = try Harness(scale: 0.01, helper: FakeHelper())
        let stray = try startStray()
        defer { if stray.isRunning { stray.terminate() } }
        let record = try #require(ServiceRecord(pid: stray.processIdentifier))
        try record.save(for: "demo", in: harness.directories)

        await harness.store.start()
        try await eventually("the stray group is gone") { kill(-stray.processIdentifier, 0) != 0 }
        #expect(!FileManager.default.fileExists(atPath: recordFile(harness).path(percentEncoded: false)))
        await harness.store.shutdown()
    }

    @Test func leavesARecycledProcessIdentifierAlone() async throws {
        let harness = try Harness(scale: 0.01, helper: FakeHelper())
        let stray = try startStray()
        defer { if stray.isRunning { stray.terminate() } }
        // The same pid with another start time: not the process the record was written for.
        var record = try #require(ServiceRecord(pid: stray.processIdentifier))
        record.startSeconds -= 1
        try record.save(for: "demo", in: harness.directories)
        try harness.temporary.write("not json", to: "Toolsy/Run/broken.json")

        await harness.store.start()
        #expect(stray.isRunning)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: recordFile(harness).deletingLastPathComponent().path(percentEncoded: false))
        #expect(leftovers.isEmpty, "stale and unreadable records are dropped")
        await harness.store.shutdown()
    }

    @Test func neverSignalsReservedProcessGroups() async {
        // As a negated target, 0 is the caller's own group and 1 is every process it may signal.
        for pid in [Int32(0), 1, -5] {
            #expect(ServiceRecord(pid: pid).map(\.isRunning) != true)
            await terminateProcessGroup(ledBy: pid, grace: .zero)
        }
    }
}

extension Double {
    var asPID: Int32 { Int32(self) }
}
