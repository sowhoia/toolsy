import Foundation
import Testing
@testable import ToolsyEngine
import ToolsyShared

private let privilegedMod = manifest(#"""
    "commands": {
        "repair": {"exec": "bin/tool", "args": ["repair"], "privileged": true, "stdin": true},
        "status": {"exec": "bin/tool", "privileged": true}
    },
    "lifecycle": {"refresh": {"command": "status", "every": 1}},
    "ui": [{"type": "button", "label": "Repair", "command": "repair", "value": 3}]
    """#)

private let tool = ["bin/tool": "echo should not run as the user; exit 1"]

/// A task started from inside the fake helper, for the test to wait on.
private actor StartedTask {
    private(set) var task: Task<Void, Never>?

    func set(_ task: Task<Void, Never>) {
        self.task = task
    }
}

@MainActor @Suite struct PrivilegedTests {
    /// A refresh still waiting on the helper wrote its stale answer over a fresher one: after the helper was
    /// updated, privileged mods kept saying that it needed an update.
    @Test func anEarlierRefreshDoesNotUndoALaterOne() async throws {
        let helper = FakeHelper(status: .needsUpdate)
        try await withHarness(helper: helper) { harness in
            await helper.set(statusDelays: [.milliseconds(300)])
            let earlier = Task { await harness.store.refreshAccess() }
            try await Task.sleep(for: .milliseconds(50))
            await helper.set(status: .ready)
            await harness.store.refreshAccess()
            #expect(harness.store.helperStatus == .ready)
            await earlier.value
            #expect(harness.store.helperStatus == .ready)
        }
    }

    @Test func installingInstallsTheHelperApprovesAndRuns() async throws {
        let helper = FakeHelper(status: .notInstalled)
        try await withHarness(helper: helper) { harness in
            let mod = try await harness.install(privilegedMod, scripts: tool)
            #expect(await helper.calls == ["install", "approve demo"])
            #expect(await helper.approvals["demo"] == (try ModPayload(directory: mod.folder).digest))
            #expect(mod.access == .granted && harness.store.helperStatus == .ready)

            await mod.run("repair", value: 3)
            #expect(await helper.inputs.first == CommandInput(event: .command, command: "repair", value: 3, state: ["enabled": false]))
            #expect(mod.status == "as root" && mod.error == nil)
            // The refresh that follows every other command now runs as well.
            try await eventually("the refresh finished") { mod.runningCommands.isEmpty }
            #expect(await helper.calls.suffix(2) == ["run demo repair", "run demo status"])
            #expect(await helper.inputs.last?.event == .refresh)
        }
    }

    @Test func whatIsApprovedIsWhatWasCheckedNotWhatIsOnDisk() async throws {
        let helper = FakeHelper(status: .ready)
        try await withHarness(helper: helper) { harness in
            let source = try writeMod(privilegedMod, scripts: tool, in: harness.temporary)
            let checked = try ModPayload(directory: source).digest
            let prepared = try await harness.store.prepareInstall(from: source)
            // While the confirmation is on screen someone rewrites the program, in the package and in the
            // copy waiting to be installed.
            for folder in [source, prepared.modDirectory] {
                try Data("#!/bin/sh\nid > /tmp/owned\n".utf8).write(to: folder.appending(path: "bin/tool"))
            }
            let mod = try await harness.store.commitInstall(prepared)
            #expect(await helper.approvals["demo"] == checked)
            // The installed files are not the approved ones, so nothing of the mod runs as root.
            #expect(mod.access == .notApproved(modified: true))
            await mod.run("repair")
            #expect(mod.error == PrivilegedError.notApproved(modID: "demo").localizedDescription)
            #expect(await helper.calls == ["approve demo"])
        }
    }

    @Test func filesChangedAfterInstallationLoseAccessUntilInstalledAgain() async throws {
        let helper = FakeHelper(status: .ready)
        try await withHarness(helper: helper) { harness in
            let mod = try await harness.install(privilegedMod, scripts: tool)
            #expect(mod.access == .granted)
            try Data("#!/bin/sh\necho replaced\n".utf8).write(to: mod.folder.appending(path: "bin/tool"))
            await harness.relaunch()
            let changed = try harness.mod()
            #expect(changed.access == .notApproved(modified: true))
            await changed.run("repair")
            #expect(changed.error == PrivilegedError.notApproved(modID: "demo").localizedDescription)
            // Nothing leads from the changed files to an approval; only another installation does.
            #expect(await helper.calls == ["approve demo"])
            #expect(try await harness.install(privilegedMod, scripts: tool).access == .granted)
        }
    }

    @Test func aModPutInPlaceByHandIsNotApproved() async throws {
        let helper = FakeHelper(status: .ready)
        try await withHarness(helper: helper) { harness in
            try writeMod(privilegedMod, scripts: tool, in: harness.temporary, folder: "Toolsy/Mods/demo")
            await harness.relaunch()
            let mod = try harness.mod()
            #expect(mod.access == .notApproved(modified: false))
            await mod.run("repair")
            #expect(mod.error == PrivilegedError.notApproved(modID: "demo").localizedDescription)
            #expect(await helper.calls.isEmpty)
        }
    }

    @Test func scheduledRefreshWithoutAccessIsSkippedSilently() async throws {
        let helper = FakeHelper(status: .ready)
        try await withHarness(helper: helper) { harness in
            try writeMod(privilegedMod, scripts: tool, in: harness.temporary, folder: "Toolsy/Mods/demo")
            await harness.relaunch()
            let mod = try harness.mod()
            harness.store.isPanelVisible = true
            try await Task.sleep(for: .milliseconds(150))
            #expect(mod.error == nil)
            #expect(await helper.calls.isEmpty)
        }
    }

    @Test func withoutTheHelperNothingRuns() async throws {
        let helper = FakeHelper(status: .ready)
        try await withHarness(helper: helper) { harness in
            let mod = try await harness.install(privilegedMod, scripts: tool)
            try await harness.store.uninstallHelper()
            #expect(mod.access == .helperUnavailable(.notInstalled))
            await mod.run("repair", value: 3)
            #expect(mod.error == PrivilegedError.helperUnavailable(.notInstalled).localizedDescription)
            #expect(await helper.calls == ["approve demo", "uninstall"])
        }
    }

    @Test func updatingTheHelperKeepsApprovals() async throws {
        let helper = FakeHelper(status: .ready)
        try await withHarness(helper: helper) { harness in
            try await harness.install(privilegedMod, scripts: tool)
            // Toolsy was updated: the helper no longer answers this build.
            await helper.set(status: .needsUpdate)
            await harness.relaunch()
            let mod = try harness.mod()
            #expect(mod.access == .helperUnavailable(.needsUpdate))
            try await harness.store.installHelper()
            #expect(harness.store.helperStatus == .ready && mod.access == .granted)
            #expect(await helper.calls == ["approve demo", "install"])
        }
    }

    @Test func dismissingThePromptInstallsNothing() async throws {
        let helper = FakeHelper(status: .notInstalled)
        await helper.set(installError: .cancelled)
        try await withHarness(helper: helper) { harness in
            let prepared = try await harness.store.prepareInstall(from: writeMod(privilegedMod, scripts: tool, in: harness.temporary))
            await #expect(throws: PrivilegedError.cancelled) {
                try await harness.store.commitInstall(prepared)
            }
            #expect(harness.store.mods.isEmpty && harness.store.helperStatus == .notInstalled)
            let files = FileManager.default
            #expect(!files.fileExists(atPath: harness.directories.mods.appending(path: "demo").path(percentEncoded: false)))
            #expect(!files.fileExists(atPath: prepared.staging.path(percentEncoded: false)))
            #expect(await helper.calls == ["install"])
        }
    }

    @Test func aRefusedApprovalKeepsTheInstalledVersion() async throws {
        let helper = FakeHelper(status: .ready)
        try await withHarness(helper: helper) { harness in
            try await harness.install(privilegedMod, scripts: tool)
            let approved = await helper.approvals["demo"]
            await helper.set(approveErrors: [.rejected("the store is full")])
            await #expect(throws: PrivilegedError.rejected("the store is full")) {
                try await harness.install(privilegedMod, scripts: ["bin/tool": "echo version 2"])
            }
            let kept = try harness.mod()
            #expect(kept.access == .granted)
            #expect(await helper.approvals["demo"] == approved)
            #expect(try String(contentsOf: kept.folder.appending(path: "bin/tool"), encoding: .utf8).contains("should not run as the user"))
        }
    }

    @Test func anUpdateWaitsBrieflyForACommandThatIsStillFinishing() async throws {
        let helper = FakeHelper(status: .ready)
        try await withHarness(helper: helper) { harness in
            try await harness.install(privilegedMod, scripts: tool)
            let approved = await helper.approvals["demo"]
            // The helper replaces nothing under a running command; a short one is over after a retry or two.
            await helper.set(approveErrors: [.busy, .busy])
            let updated = try await harness.install(privilegedMod, scripts: ["bin/tool": "echo version 2"])
            #expect(updated.access == .granted)
            #expect(await helper.approvals["demo"] != approved)
            #expect(await helper.calls == Array(repeating: "approve demo", count: 4))

            // One that takes long fails the update, which changes nothing.
            await helper.set(approveErrors: Array(repeating: .busy, count: 10_000))
            await #expect(throws: PrivilegedError.busy) {
                try await harness.install(privilegedMod, scripts: ["bin/tool": "echo version 3"])
            }
            #expect(try harness.mod().access == .granted)
            #expect(try String(contentsOf: harness.mod().folder.appending(path: "bin/tool"), encoding: .utf8).contains("version 2"))
        }
    }

    @Test func anUpdateReplacesTheApproval() async throws {
        let helper = FakeHelper(status: .ready)
        try await withHarness(helper: helper) { harness in
            try await harness.install(privilegedMod, scripts: tool)
            let first = await helper.approvals["demo"]
            let updated = try await harness.install(privilegedMod, scripts: ["bin/tool": "echo version 2"])
            #expect(updated.access == .granted)
            #expect(await helper.approvals["demo"] != first)
            #expect(await helper.calls == ["approve demo", "approve demo"])
        }
    }

    @Test func aHelperErrorIsShownAndAccessRecomputed() async throws {
        let helper = FakeHelper(status: .ready)
        try await withHarness(helper: helper) { harness in
            let mod = try await harness.install(privilegedMod, scripts: tool)
            // The approval disappeared behind the app's back.
            await helper.set(approval: nil, for: "demo")
            await helper.set(runError: .notApproved(modID: "demo"))
            await mod.run("repair")
            #expect(mod.error == PrivilegedError.notApproved(modID: "demo").localizedDescription)
            try await eventually("access recomputed") { mod.access == .notApproved(modified: false) }
        }
    }

    @Test func approvalsOfModsNoLongerInstalledAreRevoked() async throws {
        let helper = FakeHelper(status: .ready)
        await helper.set(approval: "digest of a mod deleted by hand", for: "gone")
        try await withHarness(helper: helper) { harness in
            // Starting the store was enough. Only the approval goes: deleting a folder must not make root delete data.
            #expect(await helper.calls == ["revoke gone, data kept"])
            try await harness.install(privilegedMod, scripts: tool)
            await harness.relaunch()
            #expect(await helper.calls == ["revoke gone, data kept", "approve demo"])
            #expect(await helper.approvals.keys.sorted() == ["demo"])
            #expect(try harness.mod().access == .granted)
        }
    }

    @Test func aVersionWithoutPrivilegedCommandsTakesTheApprovalAway() async throws {
        let helper = FakeHelper(status: .ready)
        try await withHarness(helper: helper) { harness in
            try await harness.install(privilegedMod, scripts: tool)
            // Toolsy was updated meanwhile: the helper cannot be asked, so the old approval could not be taken back.
            await helper.set(status: .needsUpdate)
            await #expect(throws: PrivilegedError.helperUnavailable(.needsUpdate)) {
                try await harness.install(manifest(version: "2.0"))
            }
            #expect(try harness.mod().manifest.version == "1.0")

            await helper.set(status: .ready)
            let plain = try await harness.install(manifest(version: "2.0"))
            #expect(plain.access == .notNeeded)
            #expect(await helper.approvals.isEmpty)
            #expect(await helper.calls == ["approve demo", "revoke demo"])

            // Putting the approved files back by hand brings nothing back.
            try writeMod(privilegedMod, scripts: tool, in: harness.temporary, folder: "Toolsy/Mods/demo")
            await harness.relaunch()
            #expect(try harness.mod().access == .notApproved(modified: false))
        }
    }

    @Test func anApprovalWhoseModRunsNothingAsRootIsRevoked() async throws {
        let helper = FakeHelper(status: .ready)
        try await withHarness(helper: helper) { harness in
            // Left behind by an earlier version that was removed while the helper could not be asked.
            try await harness.install(manifest())
            await helper.set(approval: "digest of the earlier version", for: "demo")
            await harness.relaunch()
            #expect(await helper.calls == ["revoke demo, data kept"])
            #expect(await helper.approvals.isEmpty)
        }
    }

    @Test func aRevocationInProgressDoesNotMissAModInstalledMeanwhile() async throws {
        let helper = FakeHelper(status: .ready)
        try await withHarness(helper: helper) { harness in
            let store = harness.store
            await helper.set(approval: "digest of a mod deleted by hand", for: "aaa")
            await helper.set(revokeDelays: [.milliseconds(300)])
            let refresh = StartedTask()
            // A refresh reads the approvals while the new mod is approved but not yet in place, and is then
            // held up revoking the orphan before it in the list for longer than the rest of the installation takes.
            await helper.set(afterApprove: {
                await refresh.set(Task { await store.refreshAccess() })
                try? await Task.sleep(for: .milliseconds(100))
            })
            let mod = try await harness.install(privilegedMod, scripts: tool)
            await refresh.task?.value
            // The orphan is gone (both the started refresh and the installation's own one saw to it), the new mod is not.
            #expect(await !helper.calls.contains { $0.hasPrefix("revoke demo") })
            #expect(await helper.approvals.keys.sorted() == ["demo"])
            #expect(mod.access == .granted)
        }
    }

    @Test func oneInstallationOfAModAtATime() async throws {
        let helper = FakeHelper(status: .ready)
        try await withHarness(helper: helper) { harness in
            let store = harness.store
            let first = try await store.prepareInstall(from: writeMod(privilegedMod, scripts: tool, in: harness.temporary, folder: "a"))
            let second = try await store.prepareInstall(from: writeMod(privilegedMod, scripts: tool, in: harness.temporary, folder: "b"))
            await helper.set(afterApprove: { try? await Task.sleep(for: .milliseconds(100)) })
            async let installed = store.commitInstall(first)
            // Give the first one time to reach the helper.
            try await Task.sleep(for: .milliseconds(20))
            await #expect(throws: EngineError("Demo is already being installed.")) {
                try await store.commitInstall(second)
            }
            #expect(try await installed.access == .granted)
            #expect(await helper.calls == ["approve demo"])
            store.discardInstall(second)
        }
    }

    @Test func anApprovalAheadOfItsFolderIsNotAnOrphan() async throws {
        let helper = FakeHelper(status: .ready)
        try await withHarness(helper: helper) { harness in
            let store = harness.store
            // Access is recomputed at the worst moment: the helper holds the approval, the files are not in place yet.
            await helper.set(afterApprove: { await store.refreshAccess() })
            let mod = try await harness.install(privilegedMod, scripts: tool)
            #expect(mod.access == .granted)
            #expect(await helper.calls == ["approve demo"])
        }
    }
}

@MainActor @Suite struct UninstallTests {
    /// Hooks log to a file outside the mod, which removal deletes.
    private func hookedMod(_ harness: Harness, privileged: Bool = false) -> (manifest: String, scripts: [String: String]) {
        let log = harness.temporary.url.appending(path: "hooks.log").path(percentEncoded: false)
        let manifestJSON = manifest(#"""
            "commands": {"on": {"exec": "hook.sh"}, "off": {"exec": "hook.sh"}, "bye": {"exec": "hook.sh"}, "root": {"shell": "true", "privileged": \#(privileged)}},
            "lifecycle": {"enable": "on", "disable": "off", "uninstall": "bye"}
            """#)
        let script = #"""
            sleep "$(cat "$TOOLSY_DATA_DIR/$TOOLSY_EVENT-delay" 2>/dev/null || echo 0)"
            echo "$TOOLSY_EVENT" >> '\#(log)'
            exit "$(cat "$TOOLSY_DATA_DIR/$TOOLSY_EVENT-status" 2>/dev/null || echo 0)"
            """#
        return (manifestJSON, ["hook.sh": script])
    }

    private func hookLog(_ harness: Harness) -> [String] {
        let text = (try? String(contentsOf: harness.temporary.url.appending(path: "hooks.log"), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").map(String.init)
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    @Test func runsHooksInOrderAndDeletesEverything() async throws {
        try await withHarness { harness in
            let fixture = hookedMod(harness)
            let mod = try await harness.install(fixture.manifest, scripts: fixture.scripts)
            await mod.setEnabled(true)
            let files = [harness.directories.mods.appending(path: "demo"), harness.directories.state.appending(path: "demo.json"), harness.directories.data.appending(path: "demo")]
            #expect(files.allSatisfy(exists))

            try await harness.store.uninstall(mod)
            #expect(hookLog(harness) == ["enable", "disable", "uninstall"])
            #expect(harness.store.mods.isEmpty)
            #expect(!files.contains(where: exists))
            await harness.relaunch()
            #expect(harness.store.mods.isEmpty && harness.store.loadProblems.isEmpty)
        }
    }

    @Test func aModThatIsOffOnlyRunsUninstall() async throws {
        try await withHarness { harness in
            let fixture = hookedMod(harness)
            let mod = try await harness.install(fixture.manifest, scripts: fixture.scripts)
            try await harness.store.uninstall(mod)
            #expect(hookLog(harness) == ["uninstall"])
        }
    }

    @Test func removalWaitsForASwitchChangeInFlight() async throws {
        try await withHarness { harness in
            let fixture = hookedMod(harness)
            let mod = try await harness.install(fixture.manifest, scripts: fixture.scripts)
            try harness.temporary.write("0.2", to: "Toolsy/Data/demo/enable-delay")
            let switching = Task { await mod.setEnabled(true) }
            try await eventually("switching") { mod.isSwitching }
            try await harness.store.uninstall(mod)
            await switching.value
            #expect(hookLog(harness) == ["enable", "disable", "uninstall"])
        }
    }

    @Test(arguments: ["disable", "uninstall"])
    func aFailingHookStopsRemovalUnlessForced(hook: String) async throws {
        try await withHarness { harness in
            let fixture = hookedMod(harness)
            let mod = try await harness.install(fixture.manifest, scripts: fixture.scripts)
            await mod.setEnabled(true)
            try harness.temporary.write("5", to: "Toolsy/Data/demo/\(hook)-status")

            await #expect(throws: EngineError(#""\#(hook == "disable" ? "off" : "bye")" failed: exit status 5."#)) {
                try await harness.store.uninstall(mod)
            }
            #expect(harness.store.mods.first === mod && mod.isEnabled == (hook == "disable"))
            #expect(exists(mod.folder))
            await mod.run("root")
            #expect(mod.error == nil, "the mod keeps working after a failed removal")

            try await harness.store.uninstall(mod, force: true)
            #expect(harness.store.mods.isEmpty && !exists(mod.folder))
        }
    }

    @Test func revokesTheApproval() async throws {
        let helper = FakeHelper(status: .ready)
        try await withHarness(helper: helper) { harness in
            let fixture = hookedMod(harness, privileged: true)
            let mod = try await harness.install(fixture.manifest, scripts: fixture.scripts)
            try await harness.store.uninstall(mod)
            #expect(await helper.calls == ["approve demo", "revoke demo"])
            #expect(await helper.approvals.isEmpty)
        }
    }

    @Test func aReachableHelperIsAskedWhateverTheModDeclares() async throws {
        let helper = FakeHelper(status: .ready)
        try await withHarness(helper: helper) { harness in
            let mod = try await harness.install(manifest())
            // Approved in an earlier life of this id; the listing that would notice it has not run yet.
            await helper.set(approval: "digest of an earlier version", for: "demo")
            try await harness.store.uninstall(mod)
            #expect(await helper.calls == ["revoke demo"])
            #expect(await helper.approvals.isEmpty)
        }
    }

    @Test func anOutdatedHelperStopsRemovalBeforeAnyHookUnlessForced() async throws {
        let helper = FakeHelper(status: .ready)
        try await withHarness(helper: helper) { harness in
            let fixture = hookedMod(harness, privileged: true)
            let mod = try await harness.install(fixture.manifest, scripts: fixture.scripts)
            await helper.set(status: .needsUpdate)
            await #expect(throws: PrivilegedError.helperUnavailable(.needsUpdate)) {
                try await harness.store.uninstall(mod)
            }
            #expect(hookLog(harness).isEmpty && harness.store.mods.first === mod)

            try await harness.store.uninstall(mod, force: true)
            #expect(harness.store.mods.isEmpty && !exists(mod.folder))
            #expect(await helper.approvals["demo"] != nil, "the helper could not be asked")
            // Once it can be, the approval of the mod that is gone goes too.
            try await harness.store.installHelper()
            #expect(await helper.approvals.isEmpty)
            #expect(await helper.calls == ["approve demo", "install", "revoke demo, data kept"])
        }
    }
}
