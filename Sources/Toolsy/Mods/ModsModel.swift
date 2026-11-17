import AppKit
import os
import UniformTypeIdentifiers
import ToolsyEngine
import ToolsyShared

private let logger = Logger(subsystem: ToolsyPaths.bundleIdentifier, category: "mods")

/// The mod engine as the panel uses it: the store plus the flows that need the user — installing
/// (which, for a mod with administrator commands, is also the user's consent to run them as root),
/// removing, and explaining missing administrator access. One instance lives for the life of the app
/// and is in the SwiftUI environment of every page.
@Observable
final class ModsModel {
    let store: ModStore
    let directories: ToolsyDirectories

    /// Switch positions the user asked for whose hooks have not finished (or that wait for the helper
    /// update), so the switch shows the requested position with a spinner rather than snapping back.
    private(set) var requestedSwitch: [String: Bool] = [:]
    private(set) var removing: Set<String> = []
    private(set) var isChangingHelper = false
    /// A file of the install queue is being unpacked, checked or installed.
    private(set) var isInstalling = false
    /// Mods being read from their folders again (developer mode).
    private(set) var reloading: Set<String> = []
    /// Which collapsible sections the user folded, for as long as the app runs.
    let sectionFolds = SectionFolds()

    /// Shows the panel; set by the app delegate. Installing from outside the panel (the menu bar
    /// icon, Finder) needs it on screen for its confirmation.
    @ObservationIgnored var presentPanel: () -> Void = {}
    @ObservationIgnored private let panel: PanelState
    @ObservationIgnored private let dashboard: DashboardStore
    @ObservationIgnored private var pendingInstalls: [URL] = []
    @ObservationIgnored private var installLoop: Task<Void, Never>?
    @ObservationIgnored private var isStarted = false
    @ObservationIgnored private var startTask: Task<Void, Never>?

    init(store: ModStore, directories: ToolsyDirectories, panel: PanelState, dashboard: DashboardStore) {
        self.store = store
        self.directories = directories
        self.panel = panel
        self.dashboard = dashboard
        panel.addVisibilityHandler { [weak self] visible in
            self?.store.isPanelVisible = visible
            // Closing the panel answers the open confirmation with Cancel; the rest of the queue goes too.
            if !visible { self?.pendingInstalls.removeAll() }
        }
    }

    // MARK: Lifecycle

    /// Loads the mods and starts what was on, then installs whatever was opened meanwhile.
    func start() {
        guard startTask == nil else { return }
        startTask = Task {
            await store.start()
            // Watching begins once the mods are loaded, so loading them is not taken for an edit.
            store.developerMode = FileManager.default.fileExists(atPath: developerModeFile.path(percentEncoded: false))
            isStarted = true
            startInstallLoop()
        }
    }

    /// Returns once `start()` has loaded the mods.
    func waitUntilStarted() async {
        await startTask?.value
    }

    /// Stops every service, waiting at most `limit`: a mod that hangs must not keep Toolsy from quitting.
    /// Services that outlive it are stopped by the next launch (ARCHITECTURE.md, "Running a mod").
    func shutdown(within limit: Duration) async {
        let store = store
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var resumed = false
            func finish() {
                guard !resumed else { return }
                resumed = true
                continuation.resume()
            }
            Task { [startTask] in
                // Quitting during the launch: the services being started must be stopped too.
                await startTask?.value
                await store.shutdown()
                finish()
            }
            Task {
                do { try await Task.sleep(for: limit) } catch { return }  // not cancelled: the shutdown task wins
                finish()
            }
        }
    }

    func mod(id: String) -> Mod? {
        store.mod(id: id)
    }

    // MARK: Installing

    /// The file picker of the **+** button; the chosen files go to the install queue.
    func chooseAndInstall() {
        let openPanel = NSOpenPanel()
        openPanel.title = String(localized: "Install a mod")
        openPanel.prompt = String(localized: "Install")
        openPanel.canChooseDirectories = true
        openPanel.allowsMultipleSelection = true
        openPanel.allowedContentTypes = [UTType(exportedAs: "app.toolsy.mod"), .json, .folder]
        Task { install(await panel.chooseFiles(openPanel)) }
    }

    /// Installs mod packages one after another, each after the user confirmed it in the panel.
    func install(_ urls: [URL]) {
        for url in urls where !pendingInstalls.contains(url) {
            pendingInstalls.append(url)
        }
        startInstallLoop()
    }

    private func startInstallLoop() {
        guard isStarted, installLoop == nil, !pendingInstalls.isEmpty else { return }
        installLoop = Task {
            while !pendingInstalls.isEmpty {
                let url = pendingInstalls.removeFirst()
                await installOne(url)
            }
            installLoop = nil
        }
    }

    private func installOne(_ url: URL) async {
        if !panel.isVisible { presentPanel() }
        isInstalling = true
        defer { isInstalling = false }
        let prepared: PreparedInstall
        do {
            prepared = try await store.prepareInstall(from: url)
        } catch {
            await notify(String(localized: "Couldn’t install “\(url.lastPathComponent)”"), error.localizedDescription)
            return
        }
        guard panel.isVisible, await panel.ask(Self.confirmation(for: prepared, helperStatus: store.helperStatus)) else {
            store.discardInstall(prepared)
            return
        }
        let name = prepared.manifest.name
        // Approving a mod with administrator commands may wait for the password prompt; say what is happening.
        let privileged = !prepared.privilegedCommands.isEmpty
        if privileged {
            panel.confirm(ConfirmationRequest(
                title: String(localized: "Installing “\(name)”…"),
                message: store.helperStatus == .ready ? nil : String(localized: "Enter your administrator password when macOS asks for it."),
                icon: prepared.manifest.icon ?? "puzzlepiece.extension.fill",
                iconTint: Tint.color(prepared.manifest.tint),
                confirmTitle: "",
                isProgress: true
            ))
        }
        do {
            let mod = try await panel.holdingOpen { try await store.commitInstall(prepared) }
            if privileged { panel.dismissProgress() }
            // A mod's widgets go on the dashboard when it is installed for the first time, so they are seen
            // without a trip to the editor. An update leaves the dashboard as the user arranged it.
            if !prepared.replacesInstalledMod {
                for widget in mod.manifest.widgets {
                    dashboard.add(.mod(mod.id, widget: widget.id))
                }
            }
            if panel.isVisible { panel.push(.mod(mod.id)) }
        } catch {
            if privileged { panel.dismissProgress() }
            // Dismissing the password prompt is an answer: nothing was installed, nothing to report.
            guard error as? PrivilegedError != .cancelled else { return }
            await notify(String(localized: "Couldn’t install “\(name)”"), ModInterface.message(for: error, modName: name))
        }
    }

    static func confirmation(for prepared: PreparedInstall, helperStatus: HelperStatus) -> ConfirmationRequest {
        let manifest = prepared.manifest
        var lines = [manifest.author.map { String(localized: "Version \(manifest.version) by \($0)") }
            ?? String(localized: "Version \(manifest.version)")]
        if prepared.replacesInstalledMod {
            lines.append(prepared.installedVersion.map { String(localized: "Replaces version \($0). Settings are kept.") }
                ?? String(localized: "Replaces the installed copy. Settings are kept."))
        }
        if let summary = manifest.summary, !summary.isEmpty {
            lines.append(summary)
        }
        // The author field is the author's own word; a signature is the one thing that says who made the files.
        lines.append(prepared.signature.map { String(localized: "Signed with key \($0.fingerprint).") }
            ?? String(localized: "Not signed by its author."))

        var warnings: [String] = []
        if prepared.signerChanged, let installed = prepared.installedSignature {
            warnings.append(prepared.signature.map {
                String(localized: "The installed version is signed with key \(installed.fingerprint), this one with key \($0.fingerprint). It may not come from the same author.")
            } ?? String(localized: "The installed version is signed with key \(installed.fingerprint), this one is not signed. It may not come from the same author."))
        }
        if let previous = prepared.installedManifest?.author, previous != manifest.author {
            warnings.append(manifest.author.map { String(localized: "The author named in the mod changes from “\(previous)” to “\($0)”.") }
                ?? String(localized: "The installed version names “\(previous)” as its author, this one names no author."))
        }
        let privileged = !prepared.privilegedCommands.isEmpty
        if privileged {
            // For a mod with administrator commands this confirmation is the consent to run them as root.
            warnings.append(String(localized: "Installing it lets these commands run as administrator (root), now and later, without asking again. Install it only if you trust its author."))
            warnings += [ModInterface.passwordNotice(for: helperStatus)].compactMap(\.self)
        } else {
            warnings.append(String(localized: "A mod runs its own programs with your permissions: they can open and change your files and use the network. Install it only if you trust its author."))
        }
        return ConfirmationRequest(
            title: prepared.replacesInstalledMod
                ? String(localized: "Update “\(manifest.name)”?") : String(localized: "Install “\(manifest.name)”?"),
            message: lines.joined(separator: "\n"),
            warning: warnings.joined(separator: "\n\n"),
            details: privileged ? ModInterface.privilegedCommandLines(of: manifest) : [],
            icon: manifest.icon ?? "puzzlepiece.extension.fill",
            iconTint: Tint.color(manifest.tint),
            confirmTitle: prepared.replacesInstalledMod ? String(localized: "Update") : String(localized: "Install")
        )
    }

    // MARK: Using a mod

    /// Flips the main switch. When the hook that runs is privileged and the mod lacks access, explains
    /// what is wrong instead (and, after a helper update, flips it).
    func setEnabled(_ mod: Mod, _ on: Bool) {
        guard mod.hasSwitch, !mod.isSwitching, requestedSwitch[mod.id] == nil, on != mod.isEnabled else { return }
        let hook = on ? mod.manifest.lifecycle.enable : mod.manifest.lifecycle.disable
        requestedSwitch[mod.id] = on
        withAccess(to: mod, for: hook) {
            await mod.setEnabled(on)
        } finally: { [self] in
            requestedSwitch[mod.id] = nil
        }
    }

    /// Stores a bound control's value and runs its command; with a privileged command the mod lacks
    /// access for, explains what is wrong instead.
    func setValue(_ value: JSONValue, for key: String, command: String?, of mod: Mod) {
        // Synchronously in the usual case: a slider that just let go must not show its old value for a frame.
        guard ModInterface.isPrivileged(command, in: mod.manifest), mod.needsAccess else {
            return mod.setValue(value, for: key, command: command)
        }
        withAccess(to: mod, for: command) {
            mod.setValue(value, for: key, command: command)
        }
    }

    /// Runs a command for a button or list row, unless it needs access the mod lacks.
    func run(_ command: String, key: String? = nil, value: JSONValue? = nil, of mod: Mod) {
        withAccess(to: mod, for: command) {
            await mod.run(command, key: key, value: value)
        }
    }

    /// The fix for the mod's missing access, offered on its page: update the helper or install again.
    func fixAccess(of mod: Mod) {
        guard let remedy = ModInterface.remedy(for: mod.access) else { return }
        switch remedy {
        case .updateHelper: installHelper()
        case .reinstall, .reinstallModified: chooseAndInstall()
        }
    }

    /// Runs `action` at once unless `command` is privileged and the mod lacks access. Then it explains in
    /// the panel what is wrong and offers the fix: after a helper update that restored access the action
    /// runs; after choosing a package to install it does not (the user starts it again on the new version).
    /// `finally` runs in every case once the action ran or was dropped.
    private func withAccess(to mod: Mod, for command: String?, _ action: @escaping () async -> Void,
                            finally: @escaping () -> Void = {}) {
        guard ModInterface.isPrivileged(command, in: mod.manifest), let remedy = ModInterface.remedy(for: mod.access) else {
            Task {
                await action()
                finally()
            }
            return
        }
        Task {
            defer { finally() }
            let explanation = ModInterface.explanation(of: remedy, modName: mod.manifest.name)
            let fix = await panel.ask(ConfirmationRequest(
                title: explanation.title,
                message: explanation.message,
                icon: remedy == .reinstallModified ? "exclamationmark.triangle.fill" : "lock.fill",
                iconTint: remedy == .reinstallModified ? .red : .orange,
                confirmTitle: remedy == .updateHelper ? String(localized: "Update…") : String(localized: "Choose File…"),
                isDestructive: remedy == .reinstallModified
            ))
            guard fix else { return }
            switch remedy {
            case .updateHelper:
                guard await changeHelper({ try await self.store.installHelper() }), mod.access == .granted else { return }
                await action()
            case .reinstall, .reinstallModified:
                chooseAndInstall()
            }
        }
    }

    // MARK: Removing

    func remove(_ mod: Mod) {
        guard !removing.contains(mod.id) else { return }
        Task {
            let switchedOff = mod.hasSwitch && mod.isEnabled
            let confirmed = await panel.ask(ConfirmationRequest(
                title: String(localized: "Remove “\(mod.manifest.name)”?"),
                message: switchedOff
                    ? String(localized: "It is switched off first. Its settings and data are deleted.")
                    : String(localized: "Its settings and data are deleted."),
                icon: mod.manifest.icon ?? "puzzlepiece.extension.fill",
                iconTint: Tint.color(mod.manifest.tint),
                confirmTitle: String(localized: "Remove"),
                isDestructive: true
            ))
            guard confirmed else { return }
            await uninstall(mod, force: false)
        }
    }

    private func uninstall(_ mod: Mod, force: Bool) async {
        removing.insert(mod.id)
        do {
            // Hooks the mod runs on the way out may be privileged and need the helper's prompt.
            try await panel.holdingOpen { try await store.uninstall(mod, force: force) }
            removing.remove(mod.id)
            dashboard.removeWidgets(ofMod: mod.id)
            sectionFolds.forget(modID: mod.id)
            if panel.currentPage == .mod(mod.id) { panel.pop() }
        } catch {
            removing.remove(mod.id)
            guard !force else {
                return await notify(String(localized: "Couldn’t remove “\(mod.manifest.name)”"),
                                    ModInterface.message(for: error, modName: mod.manifest.name))
            }
            let removeAnyway = await panel.ask(ConfirmationRequest(
                title: String(localized: "Couldn’t remove “\(mod.manifest.name)”"),
                message: error is PrivilegedError
                    ? ModInterface.message(for: error, modName: mod.manifest.name)
                    : ModInterface.displayedError(error.localizedDescription, of: mod.manifest),
                confirmTitle: String(localized: "Remove Anyway"),
                isDestructive: true
            ))
            if removeAnyway { await uninstall(mod, force: true) }
        }
    }

    func removeBrokenMod(_ problem: LoadProblem) {
        Task {
            let confirmed = await panel.ask(ConfirmationRequest(
                title: String(localized: "Remove “\(problem.folder)”?"),
                message: String(localized: "The folder of the mod, its settings and its data are deleted."),
                confirmTitle: String(localized: "Remove"),
                isDestructive: true
            ))
            guard confirmed else { return }
            do {
                try await store.removeBrokenMod(problem)
                // The folder is named by the mod's id; its widgets may be on the dashboard from before it broke.
                dashboard.removeWidgets(ofMod: problem.folder)
                sectionFolds.forget(modID: problem.folder)
            } catch {
                await notify(String(localized: "Couldn’t remove “\(problem.folder)”"), error.localizedDescription)
            }
        }
    }

    // MARK: Developer mode

    /// For mod authors: mods reload when their files change, and each mod's page shows its recent runs.
    /// Saved as a marker file in the data root rather than in user defaults, so a debug run on scratch
    /// data neither sees nor changes the user's choice.
    var developerMode: Bool {
        get { store.developerMode }
        set {
            store.developerMode = newValue
            let path = developerModeFile.path(percentEncoded: false)
            do {
                if newValue {
                    try FileManager.default.createDirectory(at: directories.root, withIntermediateDirectories: true)
                    try Data().write(to: developerModeFile)
                } else if FileManager.default.fileExists(atPath: path) {
                    try FileManager.default.removeItem(at: developerModeFile)
                }
            } catch {
                // On for this run all the same; only the next launch would not know.
                logger.error("developer mode could not be saved to \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private var developerModeFile: URL {
        directories.root.appending(path: "DeveloperMode")
    }

    /// Reads a mod from its folder again. A folder that no longer loads is listed with the load problems.
    func reload(_ mod: Mod) {
        guard reloading.insert(mod.id).inserted else { return }
        let name = mod.manifest.name
        Task {
            do {
                try await store.reload(mod.id)
                reloading.remove(mod.id)
            } catch {
                reloading.remove(mod.id)
                await notify(String(localized: "Couldn’t reload “\(name)”"), ModInterface.message(for: error, modName: name))
            }
        }
    }

    // MARK: Administrator helper

    func installHelper() {
        Task { await changeHelper { try await self.store.installHelper() } }
    }

    func uninstallHelper() {
        Task {
            let confirmed = await panel.ask(ConfirmationRequest(
                title: String(localized: "Remove the administrator helper?"),
                message: String(localized: "Mods that run commands as administrator will have to be installed again from their files, and macOS will ask for your password to install the helper again."),
                confirmTitle: String(localized: "Remove"),
                isDestructive: true
            ))
            if confirmed { await changeHelper { try await self.store.uninstallHelper() } }
        }
    }

    /// Installs, updates or removes the helper, keeping the panel open for the password prompt. Returns
    /// whether it succeeded; a dismissed prompt is no failure worth reporting.
    @discardableResult
    private func changeHelper(_ change: @escaping () async throws -> Void) async -> Bool {
        guard !isChangingHelper else { return false }
        isChangingHelper = true
        defer { isChangingHelper = false }
        do {
            try await panel.holdingOpen(change)
            return true
        } catch {
            if error as? PrivilegedError != .cancelled {
                await notify(String(localized: "The administrator helper couldn’t be changed"), ModInterface.message(for: error, modName: ""))
            }
            return false
        }
    }

    // MARK: Notices

    /// Shows a failure in the panel. With the panel closed meanwhile there is no one to tell; the log keeps it.
    private func notify(_ title: String, _ message: String) async {
        guard panel.isVisible else {
            logger.error("\(title, privacy: .public): \(message, privacy: .public)")
            return
        }
        _ = await panel.ask(ConfirmationRequest(title: title, message: message, confirmTitle: String(localized: "OK"), cancelTitle: nil))
    }
}

extension Mod {
    /// Whether a privileged command of this mod would be refused right now.
    var needsAccess: Bool {
        ModInterface.remedy(for: access) != nil
    }
}
