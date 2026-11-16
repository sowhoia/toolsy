import Foundation
import Observation
import ToolsyShared

/// A mod folder that could not be loaded. The other mods load regardless.
public struct LoadProblem: Sendable, Equatable, Identifiable {
    /// Name of the folder under `Mods/`.
    public let folder: String
    public let message: String

    public var id: String { folder }
}

/// Every installed mod and the operations on the set: loading, installing, removing, administrator access.
@MainActor @Observable
public final class ModStore {
    /// Installed mods by name, then id.
    public private(set) var mods: [Mod] = []
    public private(set) var loadProblems: [LoadProblem] = []
    public private(set) var helperStatus: HelperStatus = .notInstalled

    /// Set while the panel is on screen: opening it refreshes every mod, and refresh schedules without
    /// `background` run only while it is true.
    public var isPanelVisible = false {
        didSet {
            guard isPanelVisible != oldValue else { return }
            for mod in mods {
                mod.panelVisibilityChanged(isPanelVisible)
            }
        }
    }

    @ObservationIgnored private let directories: ToolsyDirectories
    @ObservationIgnored private let privileged: any PrivilegedExecuting
    @ObservationIgnored private let timing: EngineTiming
    /// Mods being installed. Their approval may be ahead of their folder (see `revokeOrphanedApprovals`),
    /// and a second installation of the same mod must not run beside the first.
    @ObservationIgnored private var installing: Set<String> = []

    public convenience init(directories: ToolsyDirectories = .user, privileged: any PrivilegedExecuting) {
        self.init(directories: directories, privileged: privileged, timing: EngineTiming())
    }

    init(directories: ToolsyDirectories, privileged: any PrivilegedExecuting, timing: EngineTiming) {
        self.directories = directories
        self.privileged = privileged
        self.timing = timing
    }

    /// Loads every mod from disk, then restarts the services of the mods that were on. Call once at launch.
    public func start() async {
        await ServiceRecord.stopSurvivors(in: directories, grace: timing.killGrace)
        let folders: [URL]
        do {
            folders = try FileManager.default.contentsOfDirectory(
                at: directories.mods, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
            )
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            folders = []
        } catch {
            loadProblems.append(LoadProblem(folder: directories.mods.lastPathComponent, message: error.localizedDescription))
            folders = []
        }
        for folder in folders.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where ModPackage.isDirectory(folder) {
            do {
                mods.append(try load(folder))
            } catch {
                loadProblems.append(LoadProblem(folder: folder.lastPathComponent, message: error.localizedDescription))
            }
        }
        sortMods()
        await refreshAccess()
        for mod in mods {
            mod.activate(panelVisible: isPanelVisible)
        }
    }

    /// Stops every service and timer without running `disable`. Call when the app quits.
    public func shutdown() async {
        await withTaskGroup { group in
            for mod in mods {
                group.addTask { await mod.close() }
            }
        }
    }

    // MARK: - Installing

    /// Unpacks and checks a `.toolsymod` file, a folder or a lone `.json` manifest without touching the
    /// installed mods. Show the result for confirmation, then `commitInstall` or `discardInstall` it.
    ///
    /// For a mod with privileged commands that confirmation is the user's consent to run them as root:
    /// show `privilegedCommands`, and say that macOS will ask for the administrator password when
    /// `helperStatus` is not `.ready`.
    public func prepareInstall(from package: URL) async throws -> PreparedInstall {
        let (manifest, payload, staging) = try await ModPackage.stage(package, nextTo: directories.mods)
        return PreparedInstall(
            manifest: manifest,
            replacesInstalledMod: FileManager.default.fileExists(atPath: folder(of: manifest.id).path(percentEncoded: false)),
            installedVersion: mods.first { $0.id == manifest.id }?.manifest.version,
            staging: staging,
            approval: manifest.requiresPrivileges ? payload : nil
        )
    }

    /// Installs a prepared mod atomically, replacing an installed mod with the same id but keeping its
    /// settings and switch position. Returns the new mod, already started.
    ///
    /// A mod with privileged commands is approved here, before its files are put in place: the helper is
    /// installed or updated when it is not ready (the system administrator prompt, `PrivilegedError.cancelled`
    /// when dismissed) and handed the bytes that were checked. This is the only place a mod is ever
    /// approved, so what runs as root is what the user confirmed and never what happens to lie in the
    /// mod's folder later. Without the approval nothing is installed. Likewise a version that runs nothing
    /// as root is installed only once the approval of the version it replaces is gone.
    @discardableResult
    public func commitInstall(_ prepared: PreparedInstall) async throws -> Mod {
        let id = prepared.manifest.id
        guard FileManager.default.fileExists(atPath: prepared.modDirectory.path(percentEncoded: false)) else {
            throw EngineError("This installation was already completed or discarded.")
        }
        guard installing.insert(id).inserted else {
            throw EngineError("\(prepared.manifest.name) is already being installed.")
        }
        defer { installing.remove(id) }
        let previous = mods.first { $0.id == id }
        await previous?.close()
        do {
            if let payload = prepared.approval {
                if await privileged.status() != .ready {
                    try await privileged.install()
                }
                try await whenNotBusy { try await self.privileged.approve(modID: id, payload: payload) }
            } else if previous?.manifest.requiresPrivileges == true {
                try await revokeApproval(of: id)
            }
            try FileManager.default.createDirectory(at: directories.mods, withIntermediateDirectories: true)
            try ModPackage.place(prepared.modDirectory, at: folder(of: id))
        } catch {
            ModPackage.remove(prepared.staging)
            // The previous version is untouched; bring it back. A failure to load it is listed in `loadProblems`.
            if previous != nil {
                _ = try? await reload(id)
            } else {
                // The helper may have been installed on the way.
                await refreshAccess()
            }
            throw error
        }
        ModPackage.remove(prepared.staging)
        return try await reload(id)
    }

    /// Makes a request the helper refuses while a privileged command of the mod runs. Such a command may
    /// still be finishing: closing a mod stops waiting for it but cannot stop it, and the helper changes
    /// nothing under it. A short one, like a status refresh, is waited for.
    private func whenNotBusy(_ request: () async throws -> Void) async throws {
        let deadline = ContinuousClock.now + timing.busyPatience
        while true {
            do {
                return try await request()
            } catch PrivilegedError.busy where ContinuousClock.now < deadline {
                try await Task.sleep(for: timing.duration(0.1))
            }
        }
    }

    /// Throws away a prepared installation and its temporary files.
    public func discardInstall(_ prepared: PreparedInstall) {
        ModPackage.remove(prepared.staging)
    }

    /// Removes a mod: switches it off (running `disable`), runs `uninstall`, revokes its administrator
    /// approval, then deletes its folder, state file and data folder. A failing step stops the removal with
    /// its error and leaves the mod installed, unless `force` is set. An approval that a forced removal
    /// could not revoke is revoked as soon as the helper can be asked again.
    public func uninstall(_ mod: Mod, force: Bool = false) async throws {
        let helper = await privileged.status()
        // Checked before any hook runs, so a removal that cannot be completed for this reason changes nothing.
        if mod.manifest.requiresPrivileges, !force, helper == .needsUpdate {
            throw PrivilegedError.helperUnavailable(.needsUpdate)
        }
        try await mod.runRemovalHooks(force: force)
        // A helper that can be asked is asked for every mod: an earlier version of this one may have been approved.
        if mod.manifest.requiresPrivileges || helper == .ready {
            do {
                try await revokeApproval(of: mod.id)
            } catch where !force {
                _ = mod.abortRemoval()
                throw error
            } catch {
                logger.error("mod \(mod.id, privacy: .public): approval not revoked: \(error.localizedDescription)")
            }
        }
        await mod.close()
        mods.removeAll { $0 === mod }
        try deleteFiles(of: mod.id)
    }

    /// Deletes a mod folder that failed to load, together with its state file, data folder and
    /// administrator approval, so the mod can be installed afresh. No hook runs: nothing of the mod
    /// could be loaded to run one.
    public func removeBrokenMod(_ problem: LoadProblem) async throws {
        guard loadProblems.contains(problem) else { return }
        if ModManifest.isValidID(problem.folder) {
            do {
                try await revokeApproval(of: problem.folder)
            } catch PrivilegedError.helperUnavailable {
                // Whether this folder had an approval is unknown; if so, `revokeOrphanedApprovals` takes it back.
            }
        }
        try deleteFiles(of: problem.folder)
        loadProblems.removeAll { $0 == problem }
    }

    /// `name` is a mod id or, for a folder that never loaded, the name of that folder under `Mods/`.
    private func deleteFiles(of name: String) throws {
        for location in [folder(of: name), PersistedState.file(for: name, in: directories),
                         directories.data.appending(path: name, directoryHint: .isDirectory)] {
            do {
                try FileManager.default.removeItem(at: location)
            } catch let error as CocoaError where error.code == .fileNoSuchFile {
                continue
            }
        }
    }

    // MARK: - Administrator access

    /// Installs or updates the helper; shows the system administrator prompt. Approvals survive an
    /// update, so mods that were approved can run their privileged commands again right away.
    public func installHelper() async throws {
        try await changingHelper { try await privileged.install() }
    }

    /// Removes the helper together with every approval: mods with privileged commands then have to be
    /// installed again. Throws `PrivilegedError.busy` while a privileged command is running.
    public func uninstallHelper() async throws {
        try await changingHelper { try await privileged.uninstall() }
    }

    /// Re-reads the helper's status and approvals and recomputes the access of every privileged mod.
    /// The store does this at launch and after everything it changes itself; call it where the helper's
    /// state is shown, since the helper can also change behind Toolsy's back.
    public func refreshAccess() async {
        helperStatus = await privileged.status()
        var approved: [String: String] = [:]
        if helperStatus == .ready {
            do {
                approved = try await privileged.approvedMods()
                await revokeOrphanedApprovals(&approved)
            } catch {
                // Access then reads "not approved"; what the user tries next surfaces the error.
                logger.error("cannot list approved mods: \(error.localizedDescription)")
            }
        }
        for mod in mods where mod.manifest.requiresPrivileges {
            await mod.updateAccess(helperStatus: helperStatus, approvedDigest: approved[mod.id])
        }
    }

    /// Revokes approvals that belong to no installed mod with privileged commands any more: the mod was
    /// removed while the helper could not be asked (see `uninstall`), its folder was deleted by hand, or
    /// the folder now holds something that runs nothing as root. Otherwise putting the approved files back
    /// would silently give them root again.
    ///
    /// The root-owned data of such a mod is left alone. Whether a folder exists is in the hands of every
    /// program of the user, and that must not be enough to make root delete anything but the approval.
    private func revokeOrphanedApprovals(_ approved: inout [String: String]) async {
        for id in approved.keys.sorted() {
            // Decided afresh for each: installations go on while an earlier revocation is awaited.
            guard !installing.contains(id), isOrphan(id) else { continue }
            do {
                try await privileged.revoke(modID: id, keepingData: true)
                approved[id] = nil
                logger.notice("revoked the approval of \(id, privacy: .public), which is no longer installed with privileged commands")
            } catch {
                logger.error("cannot revoke the approval of \(id, privacy: .public): \(error.localizedDescription)")
            }
        }
    }

    private func isOrphan(_ id: String) -> Bool {
        if let mod = mods.first(where: { $0.id == id }) {
            return !mod.manifest.requiresPrivileges
        }
        // A folder that failed to load, or cannot even be examined, is not known to be gone.
        var info = stat()
        return lstat(folder(of: id).path(percentEncoded: false), &info) != 0 && errno == ENOENT
    }

    private func changingHelper(_ change: () async throws -> Void) async throws {
        do {
            try await change()
        } catch {
            await refreshAccess()
            throw error
        }
        await refreshAccess()
    }

    /// Takes back everything the helper holds for a mod that is being removed or no longer runs anything
    /// as root: its approval and its root-owned data.
    private func revokeApproval(of id: String) async throws {
        switch await privileged.status() {
        case .notInstalled:
            // No helper, so no approvals either.
            return
        case .needsUpdate:
            // The helper is there with its approvals but does not answer this build of Toolsy.
            throw PrivilegedError.helperUnavailable(.needsUpdate)
        case .ready:
            try await whenNotBusy { try await self.privileged.revoke(modID: id, keepingData: false) }
        }
    }

    // MARK: - Loading

    private func folder(of id: String) -> URL {
        directories.mods.appending(path: id, directoryHint: .isDirectory)
    }

    private func load(_ folder: URL) throws -> Mod {
        let manifest = try ModManifest.load(from: Data(contentsOf: folder.appending(path: ModManifest.fileName)))
        try manifest.validateTemplatesAndExpressions()
        guard manifest.id == folder.lastPathComponent else {
            throw EngineError("the folder name does not match the mod's id \"\(manifest.id)\"")
        }
        return Mod(
            manifest: manifest,
            folder: folder,
            saved: try PersistedState.load(for: manifest, from: directories),
            directories: directories,
            privileged: privileged,
            timing: timing,
            accessMayHaveChanged: { [weak self] in
                Task { await self?.refreshAccess() }
            }
        )
    }

    /// Replaces whatever the store holds for `id` with a fresh load from disk and starts it.
    private func reload(_ id: String) async throws -> Mod {
        mods.removeAll { $0.id == id }
        loadProblems.removeAll { $0.folder == id }
        let mod: Mod
        do {
            mod = try load(folder(of: id))
        } catch {
            loadProblems.append(LoadProblem(folder: id, message: error.localizedDescription))
            throw error
        }
        mods.append(mod)
        sortMods()
        await refreshAccess()
        mod.activate(panelVisible: isPanelVisible)
        return mod
    }

    private func sortMods() {
        mods.sort { left, right in
            switch left.manifest.name.localizedStandardCompare(right.manifest.name) {
            case .orderedAscending: true
            case .orderedDescending: false
            case .orderedSame: left.id < right.id
            }
        }
    }
}
