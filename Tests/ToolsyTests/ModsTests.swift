import Foundation
import Testing
import ToolsyEngine
import ToolsyShared
@testable import Toolsy

// MARK: - Rendering rules

private func controls(_ json: String) throws -> [ModControl] {
    try JSONDecoder().decode([ModControl].self, from: Data(json.utf8))
}

private func manifest(_ json: String) throws -> ModManifest {
    try ModManifest.load(from: Data(json.utf8))
}

struct ModInterfaceTests {
    @Test func boundValuesReadState() {
        #expect(ModInterface.number(.number(7), fallback: 1) == 7)
        #expect(ModInterface.number(.string("7"), fallback: 1) == 1)
        #expect(ModInterface.number(nil, fallback: 3) == 3)
        #expect(ModInterface.isOn(.bool(true)))
        #expect(!ModInterface.isOn(.string("true")))
        #expect(!ModInterface.isOn(nil))
        #expect(ModInterface.text(.string("host")) == "host")
        #expect(ModInterface.text(.number(42)) == "42")
        #expect(ModInterface.text(.array([1])) == "")
        #expect(ModInterface.text(.null) == "")
    }

    @Test func stepperBounds() throws {
        let decoded = try controls("""
        [{"type": "stepper", "label": "A", "bind": "a"},
         {"type": "stepper", "label": "B", "bind": "b", "min": 5},
         {"type": "stepper", "label": "C", "bind": "c", "max": -3},
         {"type": "stepper", "label": "D", "bind": "d", "min": 1, "max": 9}]
        """)
        let steppers = decoded.compactMap { if case .stepper(let s) = $0.kind { s } else { nil } }
        #expect(ModInterface.stepperRange(steppers[0]) == nil)
        #expect(ModInterface.stepperFallback(steppers[0]) == 0)
        #expect(ModInterface.stepperRange(steppers[1]) == 5...Double.infinity)
        #expect(ModInterface.stepperFallback(steppers[1]) == 5)
        #expect(ModInterface.stepperFallback(steppers[2]) == -3)
        #expect(ModInterface.stepperRange(steppers[3]) == 1...9)
    }

    @Test func topLevelControlsGroupBetweenSections() throws {
        let ui = try controls("""
        [{"type": "text", "text": "a"}, {"type": "value", "label": "b", "value": "c"},
         {"type": "section", "children": []},
         {"type": "divider"}, {"type": "text", "text": "d"}, {"type": "divider"}, {"type": "text", "text": "e"},
         {"type": "divider"}]
        """)
        #expect(ModInterface.blocks(of: ui) == [.group([0, 1]), .section(2), .group([4]), .group([6])])
        #expect(ModInterface.blocks(of: []) == [])
    }

    @Test func arrayChartsSpanTheirLength() throws {
        let chart = try controls("""
        [{"type": "chart", "series": [{"bind": "a"}, {"bind": "b"}], "points": 30}]
        """).first.flatMap { if case .chart(let c) = $0.kind { c } else { nil } }
        let unwrapped = try #require(chart)
        #expect(ModInterface.chartCapacity(unwrapped, state: ["a": [1, 2, 3], "b": [1, 2, 3, 4, 5, 6, 7, 8]]) == 8)
        // One series recorded from numbers: the manifest's history length.
        #expect(ModInterface.chartCapacity(unwrapped, state: ["a": [1, 2], "b": 4]) == 30)
        #expect(ModInterface.chartCapacity(unwrapped, state: [:]) == 30)
        #expect(ModInterface.chartCapacity(unwrapped, state: ["a": [], "b": [1]]) == 2)
    }

    @Test func privilegedCommandsAreListedWithTheirPrograms() throws {
        let parsed = try manifest("""
        {"schema": 1, "id": "p", "name": "P", "version": "1",
         "commands": {"zap": {"exec": "bin/tool", "args": ["zap", "--now"], "privileged": true},
                      "apply": {"shell": "  echo hi  ", "privileged": true},
                      "plain": {"shell": "true"}}}
        """)
        #expect(ModInterface.privilegedCommandLines(of: parsed) == ["apply: sh -c echo hi", "zap: bin/tool zap --now"])
        #expect(ModInterface.isPrivileged("zap", in: parsed))
        #expect(!ModInterface.isPrivileged("plain", in: parsed))
        #expect(!ModInterface.isPrivileged(nil, in: parsed))
        #expect(!ModInterface.isPrivileged("missing", in: parsed))
    }

    @Test func helperErrorsAreShownInOwnWords() throws {
        let parsed = try manifest(#"{"schema": 1, "id": "vpn", "name": "VPN", "version": "1"}"#)
        let english = PrivilegedError.helperUnavailable(.notInstalled).localizedDescription
        #expect(ModInterface.displayedError(english, of: parsed)
                == ModInterface.message(for: .helperUnavailable(.notInstalled), modName: "VPN"))
        let unreachable = PrivilegedError.connection("timed out").localizedDescription
        #expect(ModInterface.displayedError(unreachable, of: parsed)
                == ModInterface.message(for: .connection("timed out"), modName: "VPN"))
        // A mod's own message stays as written.
        #expect(ModInterface.displayedError("Сервер недоступен", of: parsed) == "Сервер недоступен")
        #expect(ModInterface.displayedError(PrivilegedError.busy.localizedDescription, of: parsed)
                == ModInterface.message(for: .busy, modName: "VPN"))
        #expect(ModInterface.passwordNotice(for: .ready) == nil)
        #expect(ModInterface.passwordNotice(for: .needsUpdate) != ModInterface.passwordNotice(for: .notInstalled))
    }

    @Test func eachMissingAccessHasOneRemedy() {
        #expect(ModInterface.remedy(for: .granted) == nil)
        #expect(ModInterface.remedy(for: .notNeeded) == nil)
        #expect(ModInterface.remedy(for: .helperUnavailable(.needsUpdate)) == .updateHelper)
        #expect(ModInterface.remedy(for: .helperUnavailable(.notInstalled)) == .reinstall)
        #expect(ModInterface.remedy(for: .notApproved(modified: false)) == .reinstall)
        #expect(ModInterface.remedy(for: .notApproved(modified: true)) == .reinstallModified)
    }
}

// MARK: - Flows

/// Approves anything and runs privileged commands by answering with `result`.
private actor FakeHelper: PrivilegedExecuting {
    private(set) var installed = false
    private(set) var needsUpdate = false
    private(set) var calls: [String] = []
    private var approvals: [String: String] = [:]
    var cancelNextInstall = false

    func setCancelNextInstall() { cancelNextInstall = true }
    /// As after Toolsy was updated: approvals stay, nothing runs until `install()`.
    func setNeedsUpdate() { needsUpdate = true }
    func clearCalls() { calls = [] }

    func status() -> HelperStatus { !installed ? .notInstalled : needsUpdate ? .needsUpdate : .ready }

    func install() throws {
        calls.append("install")
        if cancelNextInstall {
            cancelNextInstall = false
            throw PrivilegedError.cancelled
        }
        installed = true
        needsUpdate = false
    }

    func uninstall() { installed = false; approvals = [:] }

    func approvedMods() throws -> [String: String] { approvals }

    func approve(modID: String, payload: ModPayload) {
        calls.append("approve \(modID)")
        approvals[modID] = payload.digest
    }

    func revoke(modID: String, keepingData: Bool) { approvals[modID] = nil }

    func run(modID: String, command: String, input: CommandInput) -> CommandResult {
        calls.append("run \(command)")
        return CommandResult(exitCode: 0, stdout: Data(#"{"status": "as root"}"#.utf8))
    }
}

@MainActor
private final class Fixture {
    let root: URL
    let panel = PanelState()
    let helper: FakeHelper
    let model: ModsModel
    var directories: ToolsyDirectories { model.directories }

    /// A fresh app; `relaunching` starts a new one on the data and helper of an earlier one.
    init(relaunching previous: Fixture? = nil) throws {
        if let previous {
            root = previous.root
            helper = previous.helper
        } else {
            root = FileManager.default.temporaryDirectory.appending(path: "ToolsyTests-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            helper = FakeHelper()
        }
        let directories = ToolsyDirectories(root: root.appending(path: "data", directoryHint: .isDirectory))
        model = ModsModel(store: ModStore(directories: directories, privileged: helper), directories: directories, panel: panel)
        panel.setVisible(true)
        model.start()
    }

    func quit() async {
        await model.shutdown(within: .seconds(5))
    }

    func cleanUp() async {
        await quit()
        try? FileManager.default.removeItem(at: root)  // best effort: a temporary folder
    }

    /// A mod folder with this manifest.
    func modFolder(_ name: String, _ manifest: String) throws -> URL {
        let folder = root.appending(path: "packages/\(name)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(manifest.utf8).write(to: folder.appending(path: "mod.json"))
        return folder
    }

    func waitForDialog() async throws -> ConfirmationRequest {
        try await waitUntil("a dialog") { self.panel.dialog != nil }
        return try #require(panel.dialog)
    }

    func waitUntil(_ what: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("timed out waiting for \(what)")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

private func plainManifest(_ id: String, version: String = "1.0") -> String {
    #"{"schema": 1, "id": "\#(id)", "name": "Mod \#(id)", "version": "\#(version)", "author": "Tests", "summary": "About \#(id)"}"#
}

@MainActor
struct InstallQueueTests {
    @Test func filesInstallOneAfterAnotherEachAfterItsConfirmation() async throws {
        let fixture = try Fixture()
        let first = try fixture.modFolder("first", plainManifest("first"))
        let second = try fixture.modFolder("second", plainManifest("second"))
        let broken = try fixture.modFolder("broken", #"{"schema": 1, "id": "broken", "name": "B", "version": "1", "ui": [{"type": "slider", "label": "L", "bind": "x", "min": 3, "max": 1}]}"#)
        // The same file twice while it is queued is installed once.
        fixture.model.install([first, second, first, broken])

        let firstDialog = try await fixture.waitForDialog()
        #expect(firstDialog.title.contains("Mod first"))
        #expect(firstDialog.message?.contains("1.0") == true)
        #expect(firstDialog.message?.contains("About first") == true)
        #expect(firstDialog.warning == nil)
        fixture.panel.dismissDialog(confirmed: true)

        try await fixture.waitUntil("the first mod") { fixture.model.mod(id: "first") != nil }
        #expect(fixture.panel.currentPage == .mod("first"))

        let secondDialog = try await fixture.waitForDialog()
        #expect(secondDialog.title.contains("Mod second"))
        fixture.panel.dismissDialog(confirmed: false)

        let failure = try await fixture.waitForDialog()
        #expect(failure.cancelTitle == nil)
        #expect(failure.message?.contains("min must be less than max") == true)
        fixture.panel.dismissDialog(confirmed: true)

        try await fixture.waitUntil("the queue to finish") { !fixture.model.isInstalling && fixture.panel.dialog == nil }
        #expect(fixture.model.store.mods.map(\.id) == ["first"])
        await fixture.cleanUp()
    }

    @Test func anUpdateSaysWhatItReplacesAndAPrivilegedModWarns() async throws {
        let fixture = try Fixture()
        fixture.model.install([try fixture.modFolder("v1", plainManifest("tool", version: "1.0"))])
        _ = try await fixture.waitForDialog()
        fixture.panel.dismissDialog(confirmed: true)
        try await fixture.waitUntil("the mod") { fixture.model.mod(id: "tool") != nil }

        let v2 = try fixture.modFolder("v2", #"""
        {"schema": 1, "id": "tool", "name": "Mod tool", "version": "2.0",
         "commands": {"fix": {"exec": "bin/fix", "args": ["--all"], "privileged": true}}}
        """#)
        try FileManager.default.createDirectory(at: v2.appending(path: "bin"), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: v2.appending(path: "bin/fix"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: v2.appending(path: "bin/fix").path(percentEncoded: false))
        fixture.model.install([v2])
        let update = try await fixture.waitForDialog()
        #expect(update.message?.contains("1.0") == true)
        #expect(update.warning != nil)
        #expect(update.details == ["fix: bin/fix --all"])
        fixture.panel.dismissDialog(confirmed: true)
        try await fixture.waitUntil("version 2") { fixture.model.mod(id: "tool")?.manifest.version == "2.0" }
        await fixture.cleanUp()
    }

    @Test func closingThePanelDropsTheRestOfTheQueue() async throws {
        let fixture = try Fixture()
        fixture.model.install([try fixture.modFolder("a", plainManifest("a")), try fixture.modFolder("b", plainManifest("b"))])
        _ = try await fixture.waitForDialog()
        // As PanelController.hide does: the dialog is cancelled, then the panel reports it is gone.
        fixture.panel.dismissDialog(confirmed: false)
        fixture.panel.setVisible(false)
        try await fixture.waitUntil("the queue to stop") { !fixture.model.isInstalling }
        try await Task.sleep(for: .milliseconds(200))
        #expect(fixture.panel.dialog == nil)
        #expect(fixture.model.store.mods.isEmpty)
        await fixture.cleanUp()
    }
}

@MainActor
struct AdministratorAccessTests {
    private static let privilegedMod = #"""
    {"schema": 1, "id": "root", "name": "Root", "version": "1",
     "commands": {"on": {"shell": "true", "privileged": true}, "off": {"shell": "true", "privileged": true},
                  "plain": {"shell": "echo '{\"plain\": true}'"}},
     "lifecycle": {"enable": "on", "disable": "off"}}
    """#

    /// Installs the privileged fixture, confirming the dialog; returns the dialog that was shown.
    @discardableResult
    private func install(_ fixture: Fixture, confirm: Bool = true) async throws -> ConfirmationRequest {
        fixture.model.install([try fixture.modFolder("root", Self.privilegedMod)])
        let dialog = try await fixture.waitForDialog()
        fixture.panel.dismissDialog(confirmed: confirm)
        try await fixture.waitUntil("the install to finish") { !fixture.model.isInstalling }
        return dialog
    }

    @Test func installingAsksOnceAndApprovesWithTheHelperMissing() async throws {
        let fixture = try Fixture()
        let dialog = try await install(fixture)
        #expect(dialog.warning?.contains(try #require(ModInterface.passwordNotice(for: .notInstalled))) == true)
        #expect(dialog.details == ["off: sh -c true", "on: sh -c true"])
        let mod = try #require(fixture.model.mod(id: "root"))
        #expect(mod.access == .granted)
        #expect(await fixture.helper.calls == ["install", "approve root"])
        #expect(fixture.panel.dialog == nil)

        // With the helper ready, an update asks for consent without mentioning the password.
        let update = try await install(fixture)
        #expect(update.warning != nil)
        #expect(update.warning?.contains(try #require(ModInterface.passwordNotice(for: .notInstalled))) == false)
        await fixture.cleanUp()
    }

    @Test func aDismissedPasswordPromptInstallsNothingAndSaysNothing() async throws {
        let fixture = try Fixture()
        await fixture.helper.setCancelNextInstall()
        try await install(fixture)
        try await Task.sleep(for: .milliseconds(100))
        #expect(fixture.model.store.mods.isEmpty)
        #expect(fixture.panel.dialog == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.directories.mods.appending(path: "root").path(percentEncoded: false)))
        await fixture.cleanUp()
    }

    @Test func changedFilesBlockPrivilegedActionsAndOfferReinstalling() async throws {
        let first = try Fixture()
        try await install(first)
        await first.quit()
        // Something running as the user adds a file to the installed mod.
        try Data("#!/bin/sh\n".utf8).write(to: first.directories.mods.appending(path: "root/payload.sh"))
        await first.helper.clearCalls()

        let fixture = try Fixture(relaunching: first)
        await fixture.model.waitUntilStarted()
        let mod = try #require(fixture.model.mod(id: "root"))
        #expect(mod.access == .notApproved(modified: true))
        fixture.model.setEnabled(mod, true)
        let warning = try await fixture.waitForDialog()
        #expect(warning.isDestructive)
        #expect(warning.title == ModInterface.explanation(of: .reinstallModified, modName: "Root").title)
        #expect(warning.confirmTitle == String(localized: "Choose File…"))
        fixture.panel.dismissDialog(confirmed: false)
        try await fixture.waitUntil("the switch to settle") { fixture.model.requestedSwitch["root"] == nil }
        #expect(!mod.isEnabled)

        // Its unprivileged commands keep working; nothing ran as root.
        fixture.model.run("plain", of: mod)
        try await fixture.waitUntil("the plain command") { mod.state["plain"] == .bool(true) }
        #expect(await fixture.helper.calls.filter { $0.hasPrefix("run") }.isEmpty)
        await fixture.cleanUp()
    }

    @Test func anOutdatedHelperIsUpdatedAndThenTheActionRuns() async throws {
        let first = try Fixture()
        try await install(first)
        await first.quit()
        await first.helper.setNeedsUpdate()
        await first.helper.clearCalls()

        let fixture = try Fixture(relaunching: first)
        await fixture.model.waitUntilStarted()
        let mod = try #require(fixture.model.mod(id: "root"))
        #expect(mod.access == .helperUnavailable(.needsUpdate))
        fixture.model.setEnabled(mod, true)
        let ask = try await fixture.waitForDialog()
        #expect(ask.confirmTitle == String(localized: "Update…"))
        fixture.panel.dismissDialog(confirmed: true)
        try await fixture.waitUntil("the mod to be on") { mod.isEnabled }
        #expect(mod.access == .granted)
        #expect(await fixture.helper.calls == ["install", "run on"])
        await fixture.cleanUp()
    }
}
