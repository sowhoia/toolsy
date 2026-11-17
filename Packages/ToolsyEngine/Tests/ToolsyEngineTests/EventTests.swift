import Foundation
import Testing
@testable import ToolsyEngine
import ToolsyShared

/// Logs `<event> <command>` to the mod's log.
private let syncScript = logLine + #"; log "$TOOLSY_EVENT $TOOLSY_COMMAND""#

/// `ModStore.post`: system events start the commands mods declare for them.
@MainActor @Suite struct EventTests {
    @Test func runsTheEventCommandOfEveryModThatIsOn() async throws {
        try await withHarness { harness in
            let switched = try await harness.install(manifest(id: "switched", #"""
                "commands": {"sync": {"shell": ". ./sync.sh"}, "on": {"shell": "true"}},
                "lifecycle": {"enable": "on", "events": {"wake": "sync"}}
                """#), scripts: ["sync.sh": syncScript])
            let widget = try await harness.install(manifest(id: "widget", #"""
                "commands": {"sync": {"shell": ". ./sync.sh"}},
                "lifecycle": {"events": {"wake": "sync", "network": "sync"}}
                """#), scripts: ["sync.sh": syncScript])
            try await harness.install(manifest(id: "deaf", #""commands": {"x": {"shell": "true"}}"#))
            #expect(harness.store.observedEvents == [.wake, .network])

            harness.store.post(.wake)
            try await eventually("the widget ran") { harness.log(of: "widget") == ["wake sync"] && widget.runningCommands.isEmpty }
            #expect(harness.log(of: "switched").isEmpty, "a mod that is off ignores events")

            await switched.setEnabled(true)
            harness.store.post(.wake)
            harness.store.post(.power)
            try await eventually("both ran") {
                harness.log(of: "switched") == ["wake sync"] && harness.log(of: "widget").count == 2 && widget.runningCommands.isEmpty
            }
            #expect(widget.recentRuns.map(\.event) == [.wake, .wake])
        }
    }

    @Test func launchIsPostedWhenTheStoreStarts() async throws {
        try await withHarness { harness in
            try await harness.install(manifest(#"""
                "commands": {"sync": {"shell": ". ./sync.sh"}}, "lifecycle": {"events": {"launch": "sync"}}
                """#), scripts: ["sync.sh": syncScript])
            #expect(harness.log().isEmpty, "installing is no launch")
            await harness.relaunch()
            try await eventually("ran at launch") { harness.log() == ["launch sync"] }
        }
    }

    @Test func aRunAlreadyWaitingIsNotQueuedAgain() async throws {
        try await withHarness { harness in
            let mod = try await harness.install(manifest(#"""
                "commands": {"sync": {"shell": ". ./sync.sh"}, "busy": {"shell": ". ./busy.sh"}},
                "lifecycle": {"events": {"wake": "sync", "network": "sync"}}
                """#), scripts: ["sync.sh": syncScript, "busy.sh": logLine + "; log busy; sleep 0.2"])
            let busy = Task { await mod.run("busy") }
            try await eventually("busy runs") { harness.log() == ["busy"] }
            for event in [ModSystemEvent.wake, .network, .wake] {
                harness.store.post(event)
            }
            await busy.value
            try await eventually("the queue drained") { mod.runningCommands.isEmpty }
            #expect(harness.log() == ["busy", "wake sync"])
        }
    }

    @Test func aPrivilegedEventCommandWithoutAccessIsSkippedSilently() async throws {
        let helper = FakeHelper(status: .ready)
        try await withHarness(helper: helper) { harness in
            try writeMod(manifest(#"""
                "commands": {"root": {"shell": "true", "privileged": true}}, "lifecycle": {"events": {"wake": "root"}}
                """#), in: harness.temporary, folder: "Toolsy/Mods/demo")
            await harness.relaunch()
            let mod = try harness.mod()
            harness.store.post(.wake)
            try await Task.sleep(for: .milliseconds(100))
            #expect(mod.error == nil && mod.runningCommands.isEmpty && mod.recentRuns.isEmpty)
            #expect(await helper.calls.isEmpty)
        }
    }

    /// MOD_FORMAT.md, "Errors": an event command's error outlives refreshes.
    @Test func anEventErrorStaysUntilAnEventOrTheUserSucceeds() async throws {
        try await withHarness { harness in
            let mod = try await harness.install(manifest(#"""
                "commands": {"status": {"shell": ". ./status.sh"}, "sync": {"shell": ". ./sync.sh"}, "ok": {"shell": "true"}},
                "lifecycle": {"refresh": {"command": "status"}, "events": {"wake": "sync"}}
                """#), scripts: [
                    "status.sh": logLine + "; log refresh",
                    "sync.sh": logLine + #"; log sync; if [ -e "$TOOLSY_DATA_DIR/broken" ]; then echo 'sync broke' >&2; exit 1; fi"#,
                ])
            let broken = "Toolsy/Data/demo/broken"
            @MainActor func wake() async throws {
                let runs = harness.log().count
                harness.store.post(.wake)
                // The event command, then the refresh that follows it.
                try await eventually("sync and refresh") { harness.log().count == runs + 2 && mod.runningCommands.isEmpty }
            }

            try harness.temporary.write("", to: broken)
            try await wake()
            #expect(mod.error == "sync broke", "the refresh that follows does not clear it")
            harness.store.isPanelVisible = true
            try await eventually("a refresh on opening the panel") { harness.log().count == 3 && mod.runningCommands.isEmpty }
            #expect(mod.error == "sync broke")

            try FileManager.default.removeItem(at: harness.temporary.url.appending(path: broken))
            try await wake()
            #expect(mod.error == nil, "the event command succeeding clears it")

            try harness.temporary.write("", to: broken)
            try await wake()
            #expect(mod.error == "sync broke")
            await mod.run("ok")
            #expect(mod.error == nil, "so does a command the user started")
        }
    }

    /// Closed while its removal waited for `disable` (Toolsy quitting), a mod made itself active again and
    /// could start its service beside whatever came after it.
    @Test func aModClosedDuringItsRemovalStaysClosed() async throws {
        try await withHarness { harness in
            let script = logLine + #"; trap '' TERM; log "$TOOLSY_EVENT"; [ "$TOOLSY_EVENT" = disable ] && sleep 0.5; true"#
            let mod = try await harness.install(manifest(#"""
                "commands": {"hook": {"shell": ". ./hook.sh"}}, "lifecycle": {"enable": "hook", "disable": "hook"}
                """#), scripts: ["hook.sh": script])
            await mod.setEnabled(true)
            let removal = Task { try await harness.store.uninstall(mod) }
            try await eventually("disable runs") { harness.log() == ["enable", "disable"] }
            await mod.close()
            await #expect(throws: (any Error).self) { try await removal.value }
            #expect(!mod.isActive)
        }
    }

    /// An update installed while the copy it replaced was being removed was then deleted by that removal.
    @Test func anUpdateIsRefusedWhileTheModIsBeingRemoved() async throws {
        try await withHarness { harness in
            let script = logLine + #"; log "$TOOLSY_EVENT"; [ "$TOOLSY_EVENT" = disable ] && sleep 0.5; true"#
            let json = manifest(#""commands": {"hook": {"shell": ". ./hook.sh"}}, "lifecycle": {"enable": "hook", "disable": "hook"}"#)
            let mod = try await harness.install(json, scripts: ["hook.sh": script])
            await mod.setEnabled(true)
            let removal = Task { try await harness.store.uninstall(mod) }
            try await eventually("disable runs") { harness.log() == ["enable", "disable"] }
            let prepared = try await harness.store.prepareInstall(from: writeMod(json, scripts: ["hook.sh": script], in: harness.temporary))
            await #expect(throws: EngineError("Demo is being removed.")) { try await harness.store.commitInstall(prepared) }
            harness.store.discardInstall(prepared)
            try await removal.value
            #expect(harness.store.mods.isEmpty)
        }
    }

    @Test func anEventPostedToAModBeingRemovedDoesNothing() async throws {
        try await withHarness { harness in
            let log = harness.temporary.url.appending(path: "outside.log").path(percentEncoded: false)
            let script = #"echo "$TOOLSY_EVENT" >> '\#(log)'; [ "$TOOLSY_EVENT" = disable ] && sleep 0.2; true"#
            let mod = try await harness.install(manifest(#"""
                "commands": {"hook": {"shell": ". ./hook.sh"}},
                "lifecycle": {"enable": "hook", "disable": "hook", "events": {"wake": "hook"}}
                """#), scripts: ["hook.sh": script])
            @MainActor func logged() -> [String] {
                ((try? String(contentsOfFile: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
            }
            await mod.setEnabled(true)
            let removal = Task { try await harness.store.uninstall(mod) }
            try await eventually("disable runs") { logged() == ["enable", "disable"] }
            harness.store.post(.wake)
            try await removal.value
            #expect(logged() == ["enable", "disable"])
            #expect(harness.store.mods.isEmpty && harness.store.observedEvents.isEmpty)
        }
    }
}

/// `notify` in patches, delivered through `ModStore.notificationHandler`.
@MainActor @Suite struct NotificationTests {
    private let emitter = manifest(name: "Pinger", #""commands": {"emit": {"shell": "printf '%s' \"$TOOLSY_VALUE\""}}"#)

    @Test func notifiesAndNeverStoresTheRequest() async throws {
        let clock = ManualClock()
        try await withHarness(clock: clock) { harness in
            let inbox = Inbox(harness.store)
            let mod = try await harness.install(emitter)
            let long = String(repeating: "t", count: 100)
            for request in [
                #""Host is down""#, #"{"title": "Ping", "body": " Back up \n"}"#, #"{"title": "  ", "body": "untitled"}"#,
                #""   ""#, #"{"title": "no body"}"#, "42", "null",
                #"{"title": "\#(long)", "body": "\#(String(repeating: "b", count: 300))"}"#,
            ] {
                await mod.run("emit", value: .string(#"{"notify": \#(request), "status": "seen"}"#))
                clock.advance(by: .seconds(3600))
            }
            #expect(inbox.texts == [
                ["Pinger", "Host is down"], ["Ping", "Back up"], ["Pinger", "untitled"],
                [String(repeating: "t", count: 79) + "…", String(repeating: "b", count: 239) + "…"],
            ])
            #expect(inbox.notifications.allSatisfy { $0.modID == "demo" && $0.modName == "Pinger" })
            #expect(mod.state["notify"] == nil && mod.status == "seen")
        }
    }

    @Test func dropsNotificationsThatComeTooSoonOrRepeat() async throws {
        let clock = ManualClock()
        try await withHarness(clock: clock) { harness in
            let inbox = Inbox(harness.store)
            let mod = try await harness.install(emitter)
            let other = try await harness.install(manifest(id: "other", name: "Other", #""commands": {"emit": {"shell": "echo \"$TOOLSY_VALUE\""}}"#))
            func notify(_ mod: Mod, _ text: String) async {
                await mod.run("emit", value: .string(#"{"notify": "\#(text)"}"#))
            }
            await notify(mod, "one")
            await notify(mod, "two")
            await notify(other, "one")
            #expect(inbox.texts == [["Pinger", "one"], ["Other", "one"]], "one per mod per interval, each mod on its own")

            clock.advance(by: harness.timing.notificationInterval)
            await notify(mod, "one")
            await notify(mod, "three")
            #expect(inbox.texts.last == ["Pinger", "three"], "a repeat within the window is dropped and does not count")

            clock.advance(by: harness.timing.repeatedNotificationWindow)
            await notify(mod, "one")
            #expect(inbox.texts == [["Pinger", "one"], ["Other", "one"], ["Pinger", "three"], ["Pinger", "one"]])
        }
    }

    @Test func aServiceLineNotifies() async throws {
        try await withHarness { harness in
            let inbox = Inbox(harness.store)
            let mod = try await harness.install(manifest(#"""
                "commands": {"watch": {"shell": "echo '{\"notify\": {\"body\": \"Watching\"}, \"up\": true}'; exec sleep 30"}},
                "lifecycle": {"service": "watch"}
                """#))
            await mod.setEnabled(true)
            try await eventually("the service reported") { mod.state["up"] == true }
            #expect(inbox.texts == [["Demo", "Watching"]])
        }
    }

    @Test func aCommandOfAReplacedModNeitherNotifiesNorChangesItsState() async throws {
        let helper = FakeHelper(status: .ready)
        try await withHarness(helper: helper) { harness in
            let inbox = Inbox(harness.store)
            let old = try await harness.install(manifest(#""commands": {"root": {"shell": "true", "privileged": true}}"#))
            await helper.set(result: CommandResult(exitCode: 0, stdout: Data(#"{"notify": "late", "status": "late"}"#.utf8)))
            await helper.set(runDelays: [.milliseconds(200)])
            let running = Task { await old.run("root") }
            try await waitUntil(helper, received: "run demo root")
            let new = try await harness.store.reload("demo")
            await running.value
            try await waitUntil(helper, received: "done demo root")
            #expect(inbox.notifications.isEmpty)
            #expect(old.status == nil && new.status == nil)
        }
    }
}
