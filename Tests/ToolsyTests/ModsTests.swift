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

    @Test func pickerOptionsComeFromTheManifestOrFromState() throws {
        let pickers = try controls("""
        [{"type": "picker", "bind": "p", "options": ["a", "b"]},
         {"type": "picker", "bind": "q", "optionsFrom": "choices"}]
        """).compactMap { if case .picker(let p) = $0.kind { p } else { nil } }
        let fixed = pickers[0], fromState = pickers[1]
        #expect(ModInterface.options(of: fixed, state: ["choices": ["x"]]).map(\.value) == ["a", "b"])
        // Until the key holds an array the picker has no options.
        #expect(ModInterface.options(of: fromState, state: [:]).isEmpty)
        #expect(ModInterface.options(of: fromState, state: ["choices": "x"]).isEmpty)
        // Elements of another shape are skipped.
        let mixed = ModInterface.options(of: fromState, state: ["choices": [1, ["value": "v", "label": "V"], ["label": "no value"], "w"]])
        #expect(mixed.map(\.value) == ["v", "w"])
        #expect(mixed.map(\.label) == ["V", "w"])
        // The list follows the state as it changes, up to 32 options.
        let many = JSONValue.array((0..<40).map { .string("o\($0)") })
        #expect(ModInterface.options(of: fromState, state: ["choices": many]).count == 32)
    }

    @Test func runsAreDescribedInWords() {
        #expect(ModInterface.text(for: .failed(exitCode: 3)) == "Failed with code 3")
        #expect(ModInterface.text(for: .exited(status: 1)) == "Service exited with code 1")
        #expect(ModInterface.text(for: .couldNotStart("no such file")) == "Couldn’t start: no such file")
        #expect(ModInterface.text(for: .succeeded) == "Succeeded")
        let failures: [CommandRun.Outcome] = [.failed(exitCode: 1), .timedOut, .couldNotStart(""), .refused, .exited(status: 1)]
        #expect(failures.allSatisfy(ModInterface.isFailure))
        // A service ending with status 0 switches its mod off on purpose.
        #expect(![CommandRun.Outcome.succeeded, .started, .restarted, .exited(status: 0)].contains(where: ModInterface.isFailure))
        let events: [ModEvent] = [.enable, .disable, .uninstall, .refresh, .service, .command, .launch, .wake, .network, .power]
        #expect(Set(events.map(ModInterface.text(for:))).count == events.count)
    }

    @Test func durationsReadAtTheirScale() {
        let english = Locale(identifier: "en_US")
        #expect(ModInterface.durationText(.milliseconds(3), locale: english) == "3 ms")
        #expect(ModInterface.durationText(.milliseconds(450), locale: english) == "450 ms")
        #expect(ModInterface.durationText(.milliseconds(1_234), locale: english) == "1.2 sec")
        #expect(ModInterface.durationText(.seconds(75), locale: english) == "1 min, 15 sec")
        #expect(ModInterface.durationText(.seconds(3_725), locale: english) == "1 hr, 2 min")
    }

    @Test func foldedSectionsFollowTheManifestUntilTheUserChooses() throws {
        let sections = try controls("""
        [{"type": "section", "title": "A", "collapsible": true, "collapsed": true, "children": []},
         {"type": "section", "title": "B", "collapsible": true, "children": []},
         {"type": "section", "title": "C", "children": []}]
        """).compactMap { if case .section(let s) = $0.kind { s } else { nil } }
        let folds = SectionFolds()
        func key(_ index: Int, mod: String = "m", place: ModControlPlace = .page) -> SectionFolds.Key {
            SectionFolds.Key(modID: mod, place: place, path: [index])
        }
        #expect(folds.isFolded(key(0), section: sections[0]))
        #expect(!folds.isFolded(key(1), section: sections[1]))
        #expect(!folds.isFolded(key(2), section: sections[2]))

        folds.setFolded(false, key(0))
        folds.setFolded(true, key(1))
        #expect(!folds.isFolded(key(0), section: sections[0]))
        #expect(folds.isFolded(key(1), section: sections[1]))
        // The same path in a widget's detail, or in another mod, is another section.
        #expect(!folds.isFolded(key(1, place: .widgetDetail("w")), section: sections[1]))
        #expect(!folds.isFolded(key(1, mod: "other"), section: sections[1]))

        // A removed mod's sections start over as the manifest says.
        folds.forget(modID: "m")
        #expect(folds.isFolded(key(0), section: sections[0]))
        #expect(!folds.isFolded(key(1), section: sections[1]))
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
    let dashboard: DashboardStore
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
        dashboard = DashboardStore(file: directories.root.appending(path: "Dashboard.json"), hasBattery: false)
        model = ModsModel(store: ModStore(directories: directories, privileged: helper), directories: directories, panel: panel,
                          dashboard: dashboard)
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

    /// Installs a folder made with `modFolder`, confirming it, and returns the installed mod.
    @discardableResult
    func installConfirmed(_ folder: URL, id: String) async throws -> Mod {
        model.install([folder])
        _ = try await waitForDialog()
        panel.dismissDialog(confirmed: true)
        try await waitUntil("the install to finish") { !model.isInstalling && model.mod(id: id) != nil }
        return try #require(model.mod(id: id))
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
        #expect(firstDialog.message?.contains("Not signed by its author.") == true)
        // Every mod runs programs as the user; the dialog says so, not only for administrator commands.
        #expect(firstDialog.warning?.contains("with your permissions") == true)
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

    /// The author field is the author's own word: the dialog says which key signed the files, and warns when
    /// an update comes from another key or names another author.
    @Test func theConfirmationSaysWhoSignedThePackage() async throws {
        let fixture = try Fixture()
        let author = try ModSigningKey.generate(at: fixture.root.appending(path: "author.key"))
        let stranger = try ModSigningKey.generate(at: fixture.root.appending(path: "stranger.key"))
        func package(_ name: String, version: String, by writer: String, key: String) async throws -> URL {
            let folder = try fixture.modFolder(name, #"{"schema": 1, "id": "tool", "name": "Tool", "version": "\#(version)", "author": "\#(writer)"}"#)
            let archive = fixture.root.appending(path: "\(name).toolsymod")
            _ = try await ModPackage.pack(folder, to: archive, signingKey: ModSigningKey.load(from: fixture.root.appending(path: key)))
            return archive
        }
        fixture.model.install([try await package("v1", version: "1", by: "Ann", key: "author.key")])
        let first = try await fixture.waitForDialog()
        #expect(first.message?.contains("Signed with key \(author.fingerprint).") == true)
        #expect(first.warning?.contains("may not come from the same author") == false)
        fixture.panel.dismissDialog(confirmed: true)
        try await fixture.waitUntil("the mod") { fixture.model.mod(id: "tool") != nil }

        fixture.model.install([try await package("v2", version: "2", by: "Bob", key: "stranger.key")])
        let update = try await fixture.waitForDialog()
        #expect(update.warning?.contains("The installed version is signed with key \(author.fingerprint), this one with key \(stranger.fingerprint).") == true)
        #expect(update.warning?.contains("The author named in the mod changes from “Ann” to “Bob”.") == true)
        fixture.panel.dismissDialog(confirmed: false)
        try await fixture.waitUntil("the queue to finish") { !fixture.model.isInstalling && fixture.panel.dialog == nil }
        #expect(fixture.model.mod(id: "tool")?.manifest.version == "1")
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

@MainActor
struct ModWidgetsOnDashboardTests {
    private static func widgetMod(version: String, widgets: [String]) -> String {
        let list = widgets.map { #"{"id": "\#($0)", "value": "{{n|default:0}}"}"# }.joined(separator: ", ")
        return #"{"schema": 1, "id": "w", "name": "Widgets", "version": "\#(version)", "widgets": [\#(list)]}"#
    }

    @Test func aFirstInstallPutsTheWidgetsOnTheDashboardAndAnUpdateKeepsTheUsersChoice() async throws {
        let fixture = try Fixture()
        let a = WidgetID.mod("w", widget: "a"), b = WidgetID.mod("w", widget: "b"), c = WidgetID.mod("w", widget: "c")
        let standard = fixture.dashboard.layout.widgets.map(\.id)

        try await fixture.installConfirmed(try fixture.modFolder("v1", Self.widgetMod(version: "1", widgets: ["a", "b"])), id: "w")
        #expect(fixture.dashboard.layout.widgets.map(\.id) == standard + [a, b])

        // The user takes one off; an update neither brings it back nor adds the widgets it introduces.
        fixture.dashboard.remove(a)
        try await fixture.installConfirmed(try fixture.modFolder("v2", Self.widgetMod(version: "2", widgets: ["a", "b", "c"])), id: "w")
        try await fixture.waitUntil("version 2") { fixture.model.mod(id: "w")?.manifest.version == "2" }
        #expect(fixture.dashboard.layout.widgets.map(\.id) == standard + [b])
        #expect(!fixture.dashboard.contains(c))

        // Removing the mod takes its widgets off.
        fixture.model.remove(try #require(fixture.model.mod(id: "w")))
        _ = try await fixture.waitForDialog()
        fixture.panel.dismissDialog(confirmed: true)
        try await fixture.waitUntil("the removal") { fixture.model.mod(id: "w") == nil }
        #expect(fixture.dashboard.layout.widgets.map(\.id) == standard)

        // Installed again, it is new to this Mac again.
        try await fixture.installConfirmed(try fixture.modFolder("v1", Self.widgetMod(version: "1", widgets: ["a", "b"])), id: "w")
        #expect(fixture.dashboard.layout.widgets.map(\.id) == standard + [a, b])
        await fixture.cleanUp()
    }

    @Test func removingABrokenModTakesItsWidgetsOff() async throws {
        let fixture = try Fixture()
        try await fixture.installConfirmed(try fixture.modFolder("v1", Self.widgetMod(version: "1", widgets: ["a"])), id: "w")
        await fixture.quit()
        try Data("{".utf8).write(to: fixture.directories.mods.appending(path: "w/mod.json"))

        let relaunched = try Fixture(relaunching: fixture)
        await relaunched.model.waitUntilStarted()
        let problem = try #require(relaunched.model.store.loadProblems.first { $0.folder == "w" })
        #expect(relaunched.dashboard.contains(.mod("w", widget: "a")))
        relaunched.model.removeBrokenMod(problem)
        _ = try await relaunched.waitForDialog()
        relaunched.panel.dismissDialog(confirmed: true)
        try await relaunched.waitUntil("the removal") { relaunched.model.store.loadProblems.isEmpty }
        #expect(!relaunched.dashboard.contains(.mod("w", widget: "a")))
        await relaunched.cleanUp()
    }
}

@MainActor
struct DeveloperModeTests {
    @Test func theChoiceIsRememberedInTheDataRoot() async throws {
        let first = try Fixture()
        await first.model.waitUntilStarted()
        #expect(!first.model.developerMode)
        first.model.developerMode = true
        #expect(first.model.store.developerMode)
        // Quitting stops the store's watching; that is not the user switching it off.
        await first.quit()

        let second = try Fixture(relaunching: first)
        await second.model.waitUntilStarted()
        #expect(second.model.developerMode)
        second.model.developerMode = false
        await second.quit()

        let third = try Fixture(relaunching: second)
        await third.model.waitUntilStarted()
        #expect(!third.model.developerMode)
        await third.cleanUp()
    }

    @Test func reloadingReadsTheFolderAgainAndABrokenOneComesBackWhenFixed() async throws {
        let fixture = try Fixture()
        let mod = try await fixture.installConfirmed(try fixture.modFolder("tool", plainManifest("tool")), id: "tool")
        let manifestFile = fixture.directories.mods.appending(path: "tool/mod.json")

        try Data(plainManifest("tool", version: "2.0").utf8).write(to: manifestFile)
        fixture.model.reload(mod)
        try await fixture.waitUntil("version 2") { fixture.model.mod(id: "tool")?.manifest.version == "2.0" }
        #expect(!fixture.model.reloading.contains("tool"))

        // A mistake: the failure is shown, and the folder is listed with the load problems.
        try Data(#"{"schema": 1, "id": "tool"}"#.utf8).write(to: manifestFile)
        fixture.model.reload(try #require(fixture.model.mod(id: "tool")))
        let failure = try await fixture.waitForDialog()
        #expect(failure.title == String(localized: "Couldn’t reload “Mod tool”"))
        #expect(failure.cancelTitle == nil)
        fixture.panel.dismissDialog(confirmed: true)
        #expect(fixture.model.mod(id: "tool") == nil)
        #expect(fixture.model.store.loadProblems.map(\.folder) == ["tool"])

        // Fixed, it loads again (here through developer mode, as an author editing it would see).
        fixture.model.developerMode = true
        try Data(plainManifest("tool", version: "3.0").utf8).write(to: manifestFile)
        try await fixture.waitUntil("version 3") { fixture.model.mod(id: "tool")?.manifest.version == "3.0" }
        #expect(fixture.model.store.loadProblems.isEmpty)
        fixture.model.developerMode = false
        await fixture.cleanUp()
    }

    @Test func aFolderThatIsGoneCannotBeReloaded() async throws {
        let fixture = try Fixture()
        let mod = try await fixture.installConfirmed(try fixture.modFolder("gone", plainManifest("gone")), id: "gone")
        try FileManager.default.removeItem(at: fixture.directories.mods.appending(path: "gone"))
        fixture.model.reload(mod)
        let failure = try await fixture.waitForDialog()
        #expect(failure.message == "The mods folder has no folder \"gone\".")
        fixture.panel.dismissDialog(confirmed: true)
        #expect(fixture.model.mod(id: "gone") == nil)
        await fixture.cleanUp()
    }
}

@MainActor
struct ModPreferencesOfInstalledModsTests {
    @Test func modsAreListedInTheUsersOrderAndRemovingOneForgetsIt() async throws {
        let fixture = try Fixture()
        for id in ["c", "a", "b"] {
            try await fixture.installConfirmed(try fixture.modFolder(id, plainManifest(id)), id: id)
        }
        let model = fixture.model
        #expect(model.arrangedMods.map(\.id) == ["a", "b", "c"])

        let preferences = model.preferences
        preferences.move("c", toPosition: 0, among: model.arrangedMods.map(\.id))
        preferences.setHidden(true, "c")
        preferences.setLook(ModLook(name: "Mine", tint: "pink"), of: "c", originalName: "Mod c")
        #expect(model.arrangedMods.map(\.id) == ["c", "a", "b"])

        // Kept across launches.
        await fixture.quit()
        let relaunched = try Fixture(relaunching: fixture)
        await relaunched.model.waitUntilStarted()
        #expect(relaunched.model.arrangedMods.map(\.id) == ["c", "a", "b"])
        #expect(relaunched.model.preferences.isHidden("c"))

        // Removed, the mod takes what the user chose for it along; installed again, it starts afresh.
        relaunched.model.remove(try #require(relaunched.model.mod(id: "c")))
        _ = try await relaunched.waitForDialog()
        relaunched.panel.dismissDialog(confirmed: true)
        try await relaunched.waitUntil("the removal") { relaunched.model.mod(id: "c") == nil }
        #expect(!relaunched.model.preferences.order.contains("c"))
        #expect(!relaunched.model.preferences.isHidden("c"))
        #expect(relaunched.model.preferences.look(of: "c").isEmpty)
        try await relaunched.installConfirmed(try relaunched.modFolder("c", plainManifest("c")), id: "c")
        #expect(relaunched.model.arrangedMods.map(\.id) == ["a", "b", "c"])
        await relaunched.cleanUp()
    }

    @Test func aModIsCalledAndDrawnAsTheUserLikesWhereverItIsShown() async throws {
        let fixture = try Fixture()
        let manifest = #"{"schema": 1, "id": "w", "name": "Widgets", "version": "1", "tint": "blue", "widgets": [{"id": "plain", "value": "1"}, "#
            + #"{"id": "own", "title": "Own", "icon": "star.fill", "tint": "green", "value": "2"}]}"#
        let mod = try await fixture.installConfirmed(try fixture.modFolder("w", manifest), id: "w")
        let model = fixture.model
        model.preferences.setLook(ModLook(name: "Zeta", icon: "moon.fill", tint: "pink"), of: "w", originalName: "Widgets")

        // A widget without its own title, icon or colour takes the mod's; one with them keeps them.
        let plain = try #require(WidgetInfo.resolve(.mod("w", widget: "plain"), metrics: [], mods: model))
        #expect(plain.name == "Zeta")
        #expect(plain.symbol == "moon.fill")
        #expect(plain.tint == .pink)
        #expect(plain.source == "Zeta")
        let own = try #require(WidgetInfo.resolve(.mod("w", widget: "own"), metrics: [], mods: model))
        #expect(own.name == "Own")
        #expect(own.symbol == "star.fill")
        #expect(own.tint == .green)

        // Mods never placed are listed by the name the user gave them.
        try await fixture.installConfirmed(try fixture.modFolder("m", plainManifest("m")), id: "m")
        #expect(model.arrangedMods.map(\.id) == ["m", "w"])

        // The removal asks about the mod by that name too.
        model.remove(mod)
        let question = try await fixture.waitForDialog()
        #expect(question.title == String(localized: "Remove “Zeta”?"))
        #expect(question.icon == "moon.fill")
        fixture.panel.dismissDialog(confirmed: false)
        await fixture.cleanUp()
    }
}
