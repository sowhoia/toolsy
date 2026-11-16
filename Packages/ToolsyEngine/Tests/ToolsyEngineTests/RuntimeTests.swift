import Foundation
import Testing
@testable import ToolsyEngine
import ToolsyShared

@MainActor @Suite struct SettingsTests {
    @Test func persistsSettingsAndSwitchButNotLiveState() async throws {
        try await withHarness { harness in
            let mod = try await harness.install(manifest(#"""
                "settings": {"host": "1.1.1.1", "count": 3},
                "commands": {"on": {"shell": "echo '{\"live\": 5, \"count\": 4}'"}},
                "lifecycle": {"enable": "on"}
                """#))
            #expect(mod.state["host"] == "1.1.1.1" && mod.state["count"] == 3 && !mod.isEnabled)
            mod.setValue("example.com", for: "host")
            mod.setValue(9, for: "scratch")
            await mod.setEnabled(true)
            #expect(mod.state["live"] == 5 && mod.state["count"] == 4, "a command patch may change settings")

            let file = harness.directories.state.appending(path: "demo.json")
            let saved = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: file))
            #expect(saved == ["enabled": true, "settings": ["host": "example.com", "count": 4]])

            await harness.relaunch()
            let reloaded = try harness.mod()
            #expect(reloaded.state == ["host": "example.com", "count": 4, "enabled": true])
        }
    }

    @Test func dropsSettingsTheManifestNoLongerDeclares() async throws {
        try await withHarness { harness in
            try harness.temporary.write(manifest(#""settings": {"kept": 1, "fresh": "new"}"#), to: "Toolsy/Mods/demo/mod.json")
            try harness.temporary.write(#"{"enabled": false, "settings": {"kept": 7, "gone": true}}"#, to: "Toolsy/State/demo.json")
            await harness.relaunch()
            #expect(try harness.mod().state == ["kept": 7, "fresh": "new", "enabled": false])
        }
    }

    @Test func anUnreadableStateFileIsALoadProblem() async throws {
        try await withHarness { harness in
            try harness.temporary.write(manifest(), to: "Toolsy/Mods/demo/mod.json")
            try harness.temporary.write(#"{"enabled": "yes"}"#, to: "Toolsy/State/demo.json")
            await harness.relaunch()
            #expect(harness.store.mods.isEmpty)
            #expect(harness.store.loadProblems.first?.message.contains("State/demo.json cannot be read") == true)
        }
    }
}

@MainActor @Suite struct CommandTests {
    @Test func mergesPatchesAndDeletesWithNull() async throws {
        try await withHarness { harness in
            let mod = try await harness.install(manifest(#"""
                "commands": {
                    "set": {"exec": "set.sh"}, "unset": {"exec": "unset.sh"},
                    "text": {"shell": "echo not json"}, "array": {"shell": "echo [1]"}, "quiet": {"shell": "true"}
                }
                """#), scripts: [
                    "set.sh": #"echo '{"a": 1, "b": {"x": [true]}, "status": "Ready", "level": "warn", "bad-key": 1}'"#,
                    "unset.sh": #"echo '{"a": null, "enabled": "no"}'"#,
                ])
            await mod.run("set")
            #expect(mod.state["a"] == 1 && mod.state["b"] == ["x": [true]] && mod.state["bad-key"] == nil)
            #expect(mod.status == "Ready" && mod.level == .warn)
            for command in ["text", "array", "quiet"] {
                await mod.run(command)
                #expect(mod.state["a"] == 1 && mod.error == nil, "\(command) changes nothing")
            }
            await mod.run("unset")
            #expect(mod.state["a"] == nil)
            #expect(mod.state["enabled"] == false, "enabled stays a boolean")
        }
    }

    @Test func capturesTrimmedOutput() async throws {
        try await withHarness { harness in
            let mod = try await harness.install(manifest(#""commands": {"ip": {"shell": "printf '  10.0.0.2 \\n\\n'", "capture": "ip"}}"#))
            await mod.run("ip")
            #expect(mod.state["ip"] == "10.0.0.2")
        }
    }

    @Test func passesInputEnvironmentAndDirectories() async throws {
        try await withHarness { harness in
            let mod = try await harness.install(manifest(#"""
                "settings": {"host": "h"},
                "commands": {"apply": {"exec": "bin/apply", "args": ["one"], "stdin": true}},
                "ui": [{"type": "stepper", "label": "Amount", "bind": "amount", "command": "apply"}]
                """#), scripts: ["bin/apply": #"""
                    cat > "$TOOLSY_DATA_DIR/input.json"
                    printf '%s\n' "$1" "$TOOLSY_MOD_ID" "$TOOLSY_MOD_DIR" "$TOOLSY_EVENT" "$TOOLSY_COMMAND" "$TOOLSY_KEY" "$TOOLSY_VALUE" "$TOOLSY_STATE_host" "$PWD" > "$TOOLSY_DATA_DIR/env"
                    """#])
            mod.setValue(7, for: "amount", command: "apply")
            try await eventually("the command ran") {
                mod.runningCommands.isEmpty && FileManager.default.fileExists(atPath: harness.directories.data.appending(path: "demo/env").path(percentEncoded: false))
            }
            let data = harness.directories.data.appending(path: "demo", directoryHint: .isDirectory)
            let input = try JSONDecoder().decode(CommandInput.self, from: Data(contentsOf: data.appending(path: "input.json")))
            #expect(input == CommandInput(event: .command, command: "apply", key: "amount", value: 7, state: ["host": "h", "amount": 7, "enabled": false]))
            let env = try String(contentsOf: data.appending(path: "env"), encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            let folder = mod.folder.path(percentEncoded: false)
            #expect(env.prefix(8) == ["one", "demo", folder, "command", "apply", "amount", "7", "h"])
            #expect(URL(filePath: env[8], directoryHint: .isDirectory).resolvingSymlinksInPath() == mod.folder.resolvingSymlinksInPath())
        }
    }

    @Test func choosesTheErrorMessageInOrder() async throws {
        try await withHarness { harness in
            let mod = try await harness.install(manifest(#"""
                "commands": {
                    "json": {"exec": "json.sh"}, "stderr": {"exec": "stderr.sh"}, "plain": {"shell": "exit 3"},
                    "slow": {"shell": "sleep 5", "timeout": 0.2}, "ok": {"shell": "echo '{}'"},
                    "report": {"shell": "echo '{\"error\": \"still broken\"}'"}
                }
                """#), scripts: [
                    "json.sh": #"echo '{"error": "from json", "leak": 1}'; echo 'from stderr' >&2; exit 1"#,
                    "stderr.sh": #"echo 'not json'; printf 'first\nlast line\n\n  \n' >&2; exit 2"#,
                ])
            await mod.run("json")
            #expect(mod.error == "from json")
            #expect(mod.state["leak"] == nil, "a failed command's patch is discarded")
            await mod.run("stderr")
            #expect(mod.error == "last line")
            await mod.run("plain")
            #expect(mod.error == #""plain" failed: exit status 3."#)
            await mod.run("slow")
            #expect(mod.error == #""slow" failed: timed out after 0.2 s."#)
            await mod.run("ok")
            #expect(mod.error == nil, "success clears the error")
            await mod.run("report")
            #expect(mod.error == "still broken", "unless its patch sets one")
            mod.dismissError()
            #expect(mod.error == nil)
            await mod.run("undefined")
            #expect(mod.error?.contains("no command \"undefined\"") == true)
        }
    }

    @Test func aBoundControlKeepsItsValueWhenItsCommandFails() async throws {
        try await withHarness { harness in
            let mod = try await harness.install(manifest(#""settings": {"mode": "a"}, "commands": {"apply": {"shell": "exit 1"}}"#))
            mod.setValue("b", for: "mode", command: "apply")
            #expect(mod.state["mode"] == "b")
            await mod.run("apply")
            #expect(mod.state["mode"] == "b" && mod.error != nil)
        }
    }

    @Test func runsCommandsOneAfterAnotherInStartOrder() async throws {
        try await withHarness { harness in
            let mod = try await harness.install(manifest(#"""
                "commands": {"work": {"exec": "work.sh"}},
                "ui": [{"type": "stepper", "label": "N", "bind": "n", "command": "work"}]
                """#), scripts: ["work.sh": logLine + #"; log start "$TOOLSY_VALUE"; sleep 0.05; log end "$TOOLSY_VALUE""#])
            for value in 1...4 {
                mod.setValue(.number(Double(value)), for: "n", command: "work")
            }
            #expect(mod.runningCommands == ["work"])
            await mod.run("work", value: "last")
            #expect(harness.log() == ["start 1", "end 1", "start 2", "end 2", "start 3", "end 3", "start 4", "end 4", "start last", "end last"])
            #expect(mod.runningCommands.isEmpty)
        }
    }

    @Test func pendingRunsOfALiveSliderCollapseToTheLatestValue() async throws {
        try await withHarness { harness in
            let mod = try await harness.install(manifest(#"""
                "commands": {"apply": {"exec": "apply.sh"}, "other": {"exec": "apply.sh"}},
                "ui": [{"type": "slider", "label": "L", "bind": "amount", "min": 0, "max": 10, "command": "apply", "live": true}]
                """#), scripts: ["apply.sh": logLine + #"; log "$TOOLSY_COMMAND" "$TOOLSY_VALUE"; sleep 0.1"#])
            mod.setValue(1, for: "amount", command: "apply")
            try await eventually("the first run started") { harness.log() == ["apply 1"] }
            for value in 2...5 {
                mod.setValue(.number(Double(value)), for: "amount", command: "apply")
            }
            await mod.run("other", value: "x")
            mod.setValue(6, for: "amount", command: "apply")
            mod.setValue(7, for: "amount", command: "apply")
            try await eventually("the queue drained") { mod.runningCommands.isEmpty }
            #expect(harness.log() == ["apply 1", "apply 5", "other x", "apply 7"])
            #expect(mod.state["amount"] == 7)
        }
    }
}

/// MOD_FORMAT.md, "Errors": what makes the error of a mod go away, and what does not.
@MainActor @Suite struct ErrorTests {
    /// `status.sh` is the refresh command: it logs, then prints `status-output` and exits with `status-code`
    /// from the data folder, so a test decides what each refresh reports. It is sourced rather than
    /// executed, which spares it the first-launch scan of a new executable.
    private let widget = manifest(#"""
        "commands": {
            "status": {"shell": ". ./status.sh"}, "boom": {"shell": "echo 'it broke' >&2; exit 1"}, "ok": {"shell": "true"}
        },
        "lifecycle": {"refresh": {"command": "status"}}
        """#)

    private let statusScript = logLine + #"""
        ; log refresh
        cat "$TOOLSY_DATA_DIR/status-output" 2>/dev/null
        exit "$(cat "$TOOLSY_DATA_DIR/status-code" 2>/dev/null || echo 0)"
        """#

    private func set(_ harness: Harness, _ name: String, _ contents: String) throws {
        try harness.temporary.write(contents, to: "Toolsy/Data/demo/\(name)")
    }

    /// Opens the panel, which starts one automatic refresh, and waits until it has finished.
    private func refresh(_ harness: Harness, _ mod: Mod) async throws {
        let runs = harness.log().count
        harness.store.isPanelVisible = false
        harness.store.isPanelVisible = true
        try await eventually("an automatic refresh") { harness.log().count > runs && mod.runningCommands.isEmpty }
    }

    @Test func theRefreshAfterAFailedCommandKeepsItsError() async throws {
        try await withHarness { harness in
            let mod = try await harness.install(widget, scripts: ["status.sh": statusScript])
            await mod.run("boom")
            #expect(mod.error == "it broke")
            try await eventually("the refresh that follows every command") { harness.log().count == 1 && mod.runningCommands.isEmpty }
            #expect(mod.error == "it broke")
            try await refresh(harness, mod)
            #expect(mod.error == "it broke", "however many refreshes succeed")

            await mod.run("ok")
            #expect(mod.error == nil, "a command the user started clears it by succeeding")
        }
    }

    @Test func runningTheRefreshCommandFromAControlIsUserStarted() async throws {
        try await withHarness { harness in
            let mod = try await harness.install(widget, scripts: ["status.sh": statusScript])
            await mod.run("boom")
            try await eventually("the automatic refresh") { harness.log().count == 1 && mod.runningCommands.isEmpty }
            await mod.run("status")
            #expect(mod.error == nil)
        }
    }

    @Test func refreshClearsWhatRefreshReported() async throws {
        try await withHarness { harness in
            let mod = try await harness.install(widget, scripts: ["status.sh": statusScript])
            try set(harness, "status-code", "1")
            try set(harness, "status-output", #"{"error": "cannot reach the service"}"#)
            try await refresh(harness, mod)
            #expect(mod.error == "cannot reach the service", "a failing refresh reports")

            try set(harness, "status-code", "0")
            try set(harness, "status-output", #"{"status": "fine"}"#)
            try await refresh(harness, mod)
            #expect(mod.error == nil && mod.status == "fine", "and a clean one takes it back")

            try set(harness, "status-output", #"{"error": "degraded", "level": "warn"}"#)
            try await refresh(harness, mod)
            #expect(mod.error == "degraded", "a successful refresh may report through its patch")
            try set(harness, "status-output", #"{"level": "ok"}"#)
            try await refresh(harness, mod)
            #expect(mod.error == nil)
        }
    }

    @Test func aPatchDecidesTheErrorWhoeverSendsIt() async throws {
        try await withHarness { harness in
            let mod = try await harness.install(widget, scripts: ["status.sh": statusScript])
            await mod.run("boom")
            try await eventually("the automatic refresh") { harness.log().count == 1 && mod.runningCommands.isEmpty }
            try set(harness, "status-output", #"{"error": null}"#)
            try await refresh(harness, mod)
            #expect(mod.error == nil, "an explicit null clears even an error of another source")

            try set(harness, "status-output", #"{"error": 42}"#)
            try await refresh(harness, mod)
            #expect(mod.error == nil && mod.state["error"] == nil, "only a message is an error")
        }
    }

    @Test func aServiceErrorIsClearedByTheServiceNotByRefresh() async throws {
        try await withHarness { harness in
            // The first start crashes; the restarted service stays silent until the test lets it report.
            let mod = try await harness.install(manifest(#"""
                "commands": {"watch": {"shell": ". ./svc.sh"}, "status": {"shell": ". ./status.sh"}},
                "lifecycle": {"service": "watch", "refresh": {"command": "status"}}
                """#), scripts: [
                    "status.sh": statusScript,
                    "svc.sh": #"""
                        if [ ! -e "$TOOLSY_DATA_DIR/crashed" ]; then touch "$TOOLSY_DATA_DIR/crashed"; echo 'service crashed' >&2; exit 2; fi
                        until [ -e "$TOOLSY_DATA_DIR/report" ]; do sleep 0.01; done
                        echo '{"beat": 1}'; exec sleep 30
                        """#,
                ])
            await mod.setEnabled(true)
            try await eventually("the crash is shown") { mod.error == "service crashed" }
            try await refresh(harness, mod)
            #expect(mod.error == "service crashed", "a refresh does not speak for the service")

            try set(harness, "report", "")
            try await eventually("the restarted service reports") { mod.state["beat"] == 1 }
            #expect(mod.error == nil)
        }
    }
}

@MainActor @Suite struct SwitchTests {
    private let hooks = manifest(#"""
        "commands": {"on": {"exec": "hook.sh"}, "off": {"exec": "hook.sh"}},
        "lifecycle": {"enable": "on", "disable": "off"}
        """#)

    /// `hook.sh` logs its event and exits with the status in `$TOOLSY_DATA_DIR/<event>-status`, printing `<event>-output`.
    private let hookScript = logLine + #"""
        ; log "$TOOLSY_EVENT"
        cat "$TOOLSY_DATA_DIR/$TOOLSY_EVENT-output" 2>/dev/null
        exit "$(cat "$TOOLSY_DATA_DIR/$TOOLSY_EVENT-status" 2>/dev/null || echo 0)"
        """#

    private func set(_ harness: Harness, _ name: String, _ contents: String) throws {
        try harness.temporary.write(contents, to: "Toolsy/Data/demo/\(name)")
    }

    @Test func switchesOnAndOff() async throws {
        try await withHarness { harness in
            let mod = try await harness.install(hooks, scripts: ["hook.sh": hookScript])
            #expect(mod.hasSwitch && !mod.isEnabled && !mod.isSwitching)
            let switching = Task { await mod.setEnabled(true) }
            await Task.yield()
            #expect(mod.isSwitching)
            await switching.value
            #expect(mod.isEnabled && !mod.isSwitching)
            await mod.setEnabled(true)
            await mod.setEnabled(false)
            #expect(!mod.isEnabled)
            #expect(harness.log() == ["enable", "disable"], "no hook runs for a switch already in position")
        }
    }

    @Test func aFailedEnableTurnsTheSwitchBackOff() async throws {
        try await withHarness { harness in
            let mod = try await harness.install(hooks, scripts: ["hook.sh": hookScript])
            try set(harness, "enable-status", "1")
            try set(harness, "enable-output", #"{"error": "no permission"}"#)
            await mod.setEnabled(true)
            #expect(!mod.isEnabled && mod.error == "no permission")
        }
    }

    @Test func aFailedDisableLeavesTheSwitchOn() async throws {
        try await withHarness { harness in
            let mod = try await harness.install(hooks, scripts: ["hook.sh": hookScript])
            await mod.setEnabled(true)
            try set(harness, "disable-status", "4")
            await mod.setEnabled(false)
            #expect(mod.isEnabled && mod.error == #""off" failed: exit status 4."#)
        }
    }

    @Test func aHookMayCorrectTheSwitch() async throws {
        try await withHarness { harness in
            let mod = try await harness.install(hooks, scripts: ["hook.sh": hookScript])
            try set(harness, "enable-output", #"{"enabled": false, "status": "Needs setup"}"#)
            await mod.setEnabled(true)
            #expect(!mod.isEnabled && mod.status == "Needs setup" && mod.error == nil)
        }
    }

    @Test func passiveWidgetsHaveNoSwitch() async throws {
        try await withHarness { harness in
            let mod = try await harness.install(manifest(#""commands": {"x": {"shell": "true"}}, "lifecycle": {"uninstall": "x"}"#))
            #expect(!mod.hasSwitch)
            await mod.setEnabled(true)
            #expect(!mod.isEnabled)
        }
    }
}

@MainActor @Suite struct RefreshTests {
    private func refreshing(every: Int? = nil, background: Bool = false, switchable: Bool = false, sleep: Double = 0) -> String {
        let schedule = every.map { #", "every": \#($0), "background": \#(background)"# } ?? ""
        let hooks = switchable ? #", "enable": "noop", "disable": "noop""# : ""
        return manifest(#"""
            "commands": {"status": {"exec": "status.sh", "args": ["\#(sleep)"]}, "noop": {"shell": "true"}, "other": {"shell": "true"}},
            "lifecycle": {"refresh": {"command": "status"\#(schedule)}\#(hooks)}
            """#)
    }

    private let statusScript = logLine + #"; log refresh "$TOOLSY_EVENT"; sleep "$1"; echo '{"status": "fresh"}'"#

    @Test func runsWhenThePanelOpensAndAfterOtherCommands() async throws {
        try await withHarness { harness in
            let mod = try await harness.install(refreshing(), scripts: ["status.sh": statusScript])
            #expect(harness.log().isEmpty, "installing does not refresh while the panel is closed")
            harness.store.isPanelVisible = true
            try await eventually("refresh on open") { harness.log().count == 1 }
            harness.store.isPanelVisible = false
            await mod.run("other")
            try await eventually("refresh after a command") { harness.log().count == 2 }
            await mod.run("status")
            try await Task.sleep(for: .milliseconds(100))
            #expect(harness.log() == ["refresh refresh", "refresh refresh", "refresh command"], "running the refresh command itself triggers nothing more")
            #expect(mod.status == "fresh")
        }
    }

    @Test func scheduleRunsOnlyWhileThePanelIsVisible() async throws {
        try await withHarness(scale: 0.02) { harness in
            try await harness.install(refreshing(every: 1), scripts: ["status.sh": statusScript])
            try await Task.sleep(for: .milliseconds(100))
            #expect(harness.log().isEmpty)
            harness.store.isPanelVisible = true
            try await eventually("several scheduled runs") { harness.log().count >= 4 }
            harness.store.isPanelVisible = false
            try await Task.sleep(for: .milliseconds(60))
            let stopped = harness.log().count
            try await Task.sleep(for: .milliseconds(150))
            #expect(harness.log().count == stopped)
        }
    }

    @Test func backgroundScheduleRunsWhileTheModIsOn() async throws {
        try await withHarness(scale: 0.02) { harness in
            let mod = try await harness.install(refreshing(every: 1, background: true, switchable: true), scripts: ["status.sh": statusScript])
            try await Task.sleep(for: .milliseconds(100))
            #expect(harness.log().isEmpty, "off: no background schedule")
            await mod.setEnabled(true)
            try await eventually("background runs") { harness.log().count >= 4 }
            await mod.setEnabled(false)
            try await Task.sleep(for: .milliseconds(60))
            let stopped = harness.log().count
            try await Task.sleep(for: .milliseconds(150))
            #expect(harness.log().count == stopped)
        }
    }

    @Test func backgroundScheduleAlwaysRunsForAWidget() async throws {
        try await withHarness(scale: 0.02) { harness in
            try await harness.install(refreshing(every: 1, background: true), scripts: ["status.sh": statusScript])
            try await eventually("background runs") { harness.log().count >= 3 }
            await harness.relaunch()
            let before = harness.log().count
            try await eventually("background runs after a relaunch") { harness.log().count >= before + 3 }
        }
    }

    @Test func skipsTicksWhileARefreshIsQueuedOrRunning() async throws {
        // Ticks every 10 ms, each run takes 150 ms: without skipping, runs would pile up.
        try await withHarness(scale: 0.01) { harness in
            try await harness.install(refreshing(every: 1, sleep: 0.15), scripts: ["status.sh": statusScript])
            harness.store.isPanelVisible = true
            // The first launch of a freshly written script is slow while macOS scans it; measure after it.
            try await eventually("the first run") { !harness.log().isEmpty }
            try await Task.sleep(for: .milliseconds(500))
            harness.store.isPanelVisible = false
            let runs = harness.log().count
            #expect((3...6).contains(runs))
            try await Task.sleep(for: .milliseconds(400))
            #expect(harness.log().count <= runs + 1, "at most the run in progress finishes; nothing was queued behind it")
        }
    }
}

@MainActor @Suite struct ChartHistoryTests {
    @Test func recordsNumbersUpToTheLargestPoints() async throws {
        try await withHarness { harness in
            let mod = try await harness.install(manifest(#"""
                "commands": {"emit": {"exec": "emit.sh"}},
                "ui": [
                    {"type": "chart", "series": [{"bind": "ms"}], "points": 3},
                    {"type": "section", "children": [{"type": "chart", "series": [{"bind": "ms"}, {"bind": "bars"}], "points": 5}]}
                ]
                """#), scripts: ["emit.sh": #"echo "$TOOLSY_VALUE""#])
            #expect(mod.history(of: "ms").isEmpty)
            for value in 1...7 {
                await mod.run("emit", value: .string(#"{"ms": \#(value)}"#))
            }
            await mod.run("emit", value: #"{"ms": "n/a", "other": 1}"#)
            await mod.run("emit", value: #"{"ms": 8.5}"#)
            #expect(mod.history(of: "ms") == [4, 5, 6, 7, 8.5])
            #expect(mod.history(of: "other").isEmpty, "keys no chart shows are not recorded")

            await mod.run("emit", value: #"{"bars": [3, 1.5, 2]}"#)
            #expect(mod.history(of: "bars") == [3, 1.5, 2])
        }
    }
}
