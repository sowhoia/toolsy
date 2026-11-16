import Foundation
import Testing
@testable import ToolsyEngine
import ToolsyShared

private func exists(_ url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
}

/// `ModStore.reload`: a mod read from its folder again.
@MainActor @Suite struct ReloadTests {
    @Test func readsTheModAgainKeepingSettingsAndSwitch() async throws {
        try await withHarness { harness in
            let hooks = #""commands": {"on": {"shell": "true"}}, "lifecycle": {"enable": "on"}, "settings": {"host": "a"}"#
            let first = try await harness.install(manifest(name: "Old", hooks))
            first.setValue("b", for: "host")
            await first.setEnabled(true)
            try Data(manifest(name: "New", hooks).utf8).write(to: first.folder.appending(path: "mod.json"))

            let second = try await harness.store.reload("demo")
            #expect(second !== first && second.manifest.name == "New")
            #expect(second.state == ["host": "b", "enabled": true])
            #expect(harness.store.mod(id: "demo") === second && harness.store.mods.count == 1)
            first.setValue("c", for: "host")
            #expect(second.state["host"] == "b", "the replaced instance changes nothing")
            await harness.relaunch()
            #expect(try harness.mod().state["host"] == "b")
        }
    }

    @Test func loadsAFolderAddedByHandAndReportsOneThatNoLongerLoads() async throws {
        try await withHarness { harness in
            let store = harness.store
            try writeMod(manifest(id: "hand"), in: harness.temporary, folder: "Toolsy/Mods/hand")
            let mod = try await store.reload("hand")
            #expect(store.mod(id: "hand") === mod)

            try harness.temporary.write("{", to: "Toolsy/Mods/hand/mod.json")
            await #expect(throws: (any Error).self) { try await store.reload("hand") }
            #expect(store.mod(id: "hand") == nil && store.loadProblems.map(\.folder) == ["hand"])

            try FileManager.default.removeItem(at: harness.directories.mods.appending(path: "hand"))
            await #expect(throws: EngineError(#"The mods folder has no folder "hand"."#)) { try await store.reload("hand") }
            #expect(store.loadProblems.isEmpty)
            await #expect(throws: EngineError(#""../x" is not the name of a mod folder."#)) { try await store.reload("../x") }
        }
    }

    @Test func aReloadWaitsForTheCommandStillRunning() async throws {
        try await withHarness { harness in
            // Ignores SIGTERM, so closing the old instance cannot cut it short.
            let mod = try await harness.install(manifest(#""commands": {"work": {"shell": ". ./work.sh"}}"#),
                                                scripts: ["work.sh": logLine + #"; trap '' TERM; log start "$TOOLSY_VALUE"; sleep 0.3; log end "$TOOLSY_VALUE""#])
            let running = Task { await mod.run("work", value: "old") }
            try await eventually("the old command started") { harness.log() == ["start old"] }
            let reloaded = try await harness.store.reload("demo")
            await reloaded.run("work", value: "new")
            await running.value
            #expect(harness.log() == ["start old", "end old", "start new", "end new"])
        }
    }

    /// Ignores SIGTERM, so closing its instance cannot cut it short.
    private static let slowWork = logLine + #"; trap '' TERM; log start "$TOOLSY_VALUE"; sleep 0.3; log end "$TOOLSY_VALUE""#

    @Test func aReloadAfterOneThatFailedStillWaitsForTheCommand() async throws {
        try await withHarness { harness in
            let json = manifest(#""commands": {"work": {"shell": ". ./work.sh"}}"#)
            let mod = try await harness.install(json, scripts: ["work.sh": Self.slowWork])
            let running = Task { await mod.run("work", value: "old") }
            try await eventually("the old command started") { harness.log() == ["start old"] }

            // A save with a typo, then the fix: the instance in between never existed.
            try harness.temporary.write("{", to: "Toolsy/Mods/demo/mod.json")
            await #expect(throws: (any Error).self) { try await harness.store.reload("demo") }
            try harness.temporary.write(json, to: "Toolsy/Mods/demo/mod.json")
            let reloaded = try await harness.store.reload("demo")
            await reloaded.run("work", value: "new")
            await running.value
            #expect(harness.log() == ["start old", "end old", "start new", "end new"])
        }
    }

    @Test func aFolderThatComesBackWaitsForTheCommandOfTheOneThatLeft() async throws {
        try await withHarness { harness in
            let json = manifest(#""commands": {"work": {"shell": ". ./work.sh"}}"#)
            let mod = try await harness.install(json, scripts: ["work.sh": Self.slowWork])
            let running = Task { await mod.run("work", value: "old") }
            try await eventually("the old command started") { harness.log() == ["start old"] }

            let folder = harness.directories.mods.appending(path: "demo")
            let aside = harness.temporary.url.appending(path: "aside")
            try FileManager.default.moveItem(at: folder, to: aside)
            await #expect(throws: (any Error).self) { try await harness.store.reload("demo") }
            #expect(harness.store.mod(id: "demo") == nil)
            try FileManager.default.moveItem(at: aside, to: folder)
            let reloaded = try await harness.store.reload("demo")
            await reloaded.run("work", value: "new")
            await running.value
            #expect(harness.log() == ["start old", "end old", "start new", "end new"])
        }
    }

    @Test func aModInstalledAgainWaitsForTheCommandOfTheOneRemoved() async throws {
        try await withHarness { harness in
            let json = manifest(#""commands": {"work": {"shell": ". ./work.sh"}}"#)
            let mod = try await harness.install(json, scripts: ["work.sh": Self.slowWork])
            let running = Task { await mod.run("work", value: "old") }
            try await eventually("the old command started") { harness.log() == ["start old"] }

            try await harness.store.uninstall(mod, force: true)
            let again = try await harness.install(json, scripts: ["work.sh": Self.slowWork])
            await again.run("work", value: "new")
            await running.value
            // Removing the mod deleted its data folder with the first line of the log; whatever the old
            // command still wrote comes before the new one starts.
            #expect(harness.log().suffix(2) == ["start new", "end new"])
        }
    }

    @Test func aReloadWaitsForAPrivilegedCommandStillRunning() async throws {
        let helper = FakeHelper(status: .ready)
        try await withHarness(helper: helper) { harness in
            let mod = try await harness.install(manifest(#""commands": {"root": {"shell": "true", "privileged": true}}"#))
            await helper.set(runDelays: [.milliseconds(200)])
            let running = Task { await mod.run("root") }
            try await waitUntil(helper, received: "run demo root")
            let reloaded = try await harness.store.reload("demo")
            await reloaded.run("root")
            await running.value
            #expect(await helper.calls == ["approve demo", "run demo root", "done demo root", "run demo root"])
        }
    }
}

/// `ModStore.developerMode`: the mods folder watched for edits.
@MainActor @Suite struct DeveloperModeTests {
    /// Long enough for FSEvents to report a change and the store to act on it.
    private let settle = Duration.milliseconds(500)

    @Test func reloadsAModWhoseManifestChanged() async throws {
        try await withHarness { harness in
            let store = harness.store
            store.developerMode = true
            let mod = try await harness.install(manifest(#""settings": {"host": "a"}"#))
            try await Task.sleep(for: settle)
            #expect(store.mod(id: "demo") === mod, "the store's own installation is no edit")

            let file = mod.folder.appending(path: "mod.json")
            try Data(contentsOf: file).write(to: file)
            try await Task.sleep(for: settle)
            #expect(store.mod(id: "demo") === mod, "the same bytes written again are no edit")

            mod.setValue("b", for: "host")
            try Data(manifest(name: "Edited", #""settings": {"host": "a"}"#).utf8).write(to: file)
            try await eventually("reloaded") { store.mod(id: "demo")?.manifest.name == "Edited" }
            #expect(try harness.mod().state["host"] == "b")
        }
    }

    @Test func followsFoldersThatAppearAndDisappear() async throws {
        try await withHarness { harness in
            let store = harness.store
            store.developerMode = true
            try writeMod(manifest(#"""
                "commands": {"watch": {"shell": "echo \"{\\\"pid\\\": $$}\"; exec sleep 30"}}, "lifecycle": {"service": "watch"}
                """#), in: harness.temporary, folder: "Toolsy/Mods/demo")
            try await eventually("loaded") { store.mod(id: "demo") != nil }
            let mod = try harness.mod()
            await mod.setEnabled(true)
            try await eventually("running") { mod.state["pid"] != nil }
            let pid = try #require(mod.state["pid"]?.numberValue).asPID

            try FileManager.default.removeItem(at: mod.folder)
            try await eventually("dropped") { store.mods.isEmpty }
            #expect(!isAlive(pid), "its service is stopped")
            #expect(exists(harness.directories.state.appending(path: "demo.json")), "its settings stay")

            try harness.temporary.write("{", to: "Toolsy/Mods/broken/mod.json")
            try await eventually("listed as broken") { store.loadProblems.map(\.folder) == ["broken"] }
            try FileManager.default.removeItem(at: harness.directories.mods.appending(path: "broken"))
            try await eventually("forgotten") { store.loadProblems.isEmpty }
        }
    }

    @Test func restartsTheServiceWhenItsOtherFilesChange() async throws {
        try await withHarness { harness in
            harness.store.developerMode = true
            let mod = try await harness.install(manifest(#""commands": {"watch": {"shell": ". ./svc.sh"}}, "lifecycle": {"service": "watch"}"#), scripts: [
                "svc.sh": #". ./lib.sh; echo "{\"pid\": $$, \"version\": \"$version\"}"; exec sleep 30"#,
                "lib.sh": "version=1",
            ])
            await mod.setEnabled(true)
            try await eventually("running") { mod.state["version"] == "1" }
            let pid = mod.state["pid"]
            try await Task.sleep(for: settle)
            #expect(mod.state["pid"] == pid, "installing and switching on are no edits")

            try harness.temporary.write("version=2", to: "Toolsy/Mods/demo/lib.sh")
            try await eventually("restarted with the new file") { mod.state["version"] == "2" }
            #expect(harness.store.mod(id: "demo") === mod, "restarted, not reloaded")
            #expect(mod.recentRuns.map(\.outcome) == [.started, .restarted])
        }
    }

    @Test func restartsAServiceThatWritesIntoItsFolderAtMostOncePerInterval() async throws {
        // Scale 0.2: one restart per 0.2 s at most.
        try await withHarness(scale: 0.2) { harness in
            let store = harness.store
            store.developerMode = true
            let mod = try await harness.install(manifest(#"""
                "commands": {"watch": {"shell": "touch \"$TOOLSY_MOD_DIR/cache\"; exec sleep 30"}}, "lifecycle": {"service": "watch"}
                """#))
            await mod.setEnabled(true)
            @MainActor func restarts() -> [Date] {
                mod.recentRuns.filter { $0.outcome == .restarted }.map(\.started)
            }
            try await eventually("several restarts") { restarts().count >= 6 }
            let interval = harness.timing.fileRestartInterval / .seconds(1)
            let times = restarts()
            let gaps = zip(times, times.dropFirst()).map { $1.timeIntervalSince($0) }
            // Restarts are scheduled an interval apart, and each start is late by however long the service
            // before it takes to die, so one gap can be shorter than the interval by that much. What cannot
            // happen is more restarts than the intervals that have passed.
            let elapsed = try #require(times.last).timeIntervalSince(try #require(times.first))
            #expect(elapsed >= Double(times.count - 1) * interval * 0.8, "gaps: \(gaps)")

            store.developerMode = false
            try await Task.sleep(for: settle)
            let stopped = restarts().count
            try await Task.sleep(for: settle)
            #expect(restarts().count == stopped, "without developer mode nothing is watched")
        }
    }

    @Test func aPrivilegedModEditedInPlaceIsNotApproved() async throws {
        let helper = FakeHelper(status: .ready)
        try await withHarness(helper: helper) { harness in
            let store = harness.store
            let json = manifest(#""commands": {"root": {"shell": "true", "privileged": true}}"#)
            let mod = try await harness.install(json)
            #expect(mod.access == .granted)
            store.developerMode = true
            try Data(json.replacingOccurrences(of: "true\"", with: "true; id\"").utf8).write(to: mod.folder.appending(path: "mod.json"))
            try await eventually("reloaded without access") { store.mod(id: "demo")?.access == .notApproved(modified: true) }
            #expect(try harness.mod() !== mod)
            #expect(await helper.calls == ["approve demo"])
        }
    }

    @Test func aModThatKeepsWritingIntoItsFolderDoesNotHoldUpTheOthers() async throws {
        // Real time: the service writes ten times a second, faster than changes settle.
        try await withHarness(scale: 1) { harness in
            let store = harness.store
            store.developerMode = true
            let busy = try await harness.install(manifest(id: "busy", #"""
                "commands": {"watch": {"shell": "while :; do echo x >> \"$TOOLSY_MOD_DIR/log.txt\"; sleep 0.1; done"}},
                "lifecycle": {"service": "watch"}
                """#))
            await busy.setEnabled(true)
            let other = try await harness.install(manifest(id: "other"))
            try await Task.sleep(for: .seconds(1))
            try Data(manifest(id: "other", name: "Edited").utf8).write(to: other.folder.appending(path: "mod.json"))
            try await eventually("the other mod reloaded", timeout: .seconds(8)) { store.mod(id: "other")?.manifest.name == "Edited" }
        }
    }

    @Test func switchedOnBeforeTheStoreStartsItLoadsEveryModOnce() async throws {
        let temporary = try TemporaryDirectory()
        let directories = ToolsyDirectories(root: temporary.url.appending(path: "Toolsy", directoryHint: .isDirectory))
        try writeMod(manifest(), in: temporary, folder: "Toolsy/Mods/demo")
        // A service that survived the last run and ignores SIGTERM keeps `start()` waiting for a while.
        let survivor = Process()
        survivor.executableURL = URL(filePath: "/bin/sh")
        survivor.arguments = ["-c", "trap '' TERM; sleep 30"]
        try survivor.run()
        defer { survivor.terminate() }
        try await Task.sleep(for: .milliseconds(100))
        try #require(ServiceRecord(pid: survivor.processIdentifier)).save(for: "old", in: directories)

        let store = ModStore(directories: directories, privileged: FakeHelper(), timing: EngineTiming(scale: 0.2))
        store.developerMode = true
        let starting = Task { await store.start() }
        try await Task.sleep(for: .milliseconds(150))
        try temporary.write(manifest(name: "Edited"), to: "Toolsy/Mods/demo/mod.json")
        await starting.value
        #expect(store.mods.map(\.id) == ["demo"])
        #expect(store.mod(id: "demo")?.manifest.name == "Edited")

        // From here on the folder is watched.
        try temporary.write(manifest(name: "Edited again"), to: "Toolsy/Mods/demo/mod.json")
        try await eventually("reloaded") { store.mod(id: "demo")?.manifest.name == "Edited again" }
        await store.shutdown()
    }

    @Test func watchesNothingWhileOff() async throws {
        try await withHarness { harness in
            let mod = try await harness.install(manifest())
            try Data(manifest(name: "Edited").utf8).write(to: mod.folder.appending(path: "mod.json"))
            try await Task.sleep(for: settle)
            #expect(harness.store.mod(id: "demo") === mod && mod.manifest.name == "Demo")
        }
    }
}
