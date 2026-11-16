import CryptoKit
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
    public private(set) var mods: [Mod] = [] {
        didSet { modsByID = Dictionary(uniqueKeysWithValues: mods.map { ($0.id, $0) }) }
    }
    public private(set) var loadProblems: [LoadProblem] = []
    public private(set) var helperStatus: HelperStatus = .notInstalled
    private var modsByID: [String: Mod] = [:]

    /// The system events at least one loaded mod has a command for; post only these, and observe the
    /// system only for them.
    public var observedEvents: Set<ModSystemEvent> {
        Set(mods.flatMap(\.manifest.lifecycle.events.keys))
    }

    /// Receives the notifications mods ask for in their patches, already rate-limited: at most one per mod
    /// every 5 seconds, and none that repeats one the mod gave within the last minute.
    public var notificationHandler: (@MainActor (ModNotification) -> Void)?

    /// For mod authors: while on, the store watches the mods folder and, once changes have settled,
    /// reloads a mod whose `mod.json` changed, loads a folder that appeared, drops a mod whose folder
    /// disappeared (keeping its saved settings) and restarts the running service of a mod whose other
    /// files changed. Off by default; while off nothing is watched. Nothing is ever approved this way: a
    /// privileged mod edited in place loses its administrator access, as at any other time.
    public var developerMode = false {
        didSet {
            guard developerMode != oldValue else { return }
            developerMode ? watchModsFolder() : stopWatchingModsFolder()
        }
    }

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
    @ObservationIgnored private let languages: [String]
    @ObservationIgnored private let timing: EngineTiming
    /// Mods being installed. Their approval may be ahead of their folder (see `revokeOrphanedApprovals`),
    /// and a second installation of the same mod must not run beside the first.
    @ObservationIgnored private var installing: Set<String> = []
    @ObservationIgnored private var notificationThrottle = NotificationThrottle()

    // Developer mode.
    @ObservationIgnored private var watcher: FolderWatcher?
    /// Mod folders (names under `Mods/`) with changes not acted on yet → the changed paths relative to the
    /// folder; an empty set when only the folder itself or `mod.json` may have changed.
    @ObservationIgnored private var pendingFolderChanges: [String: Set<String>] = [:]
    @ObservationIgnored private var folderSettle: Task<Void, Never>?
    /// Acting on folder changes, one batch after another.
    @ObservationIgnored private var folderChangeWork: Task<Void, Never>?
    /// Per mod: file changes up to this time are accounted for. Files the store placed and loaded itself
    /// are older, so an installation does not count as an edit.
    @ObservationIgnored private var filesSeenUntil: [String: Date] = [:]
    /// When developer mode was switched on; older changes are no edits it has to act on.
    @ObservationIgnored private var watchingSince = Date.distantPast
    /// FSEvents reported a change it could not itemise; every mod folder is looked at once things settle.
    @ObservationIgnored private var rescanPending = false
    /// Mods being reloaded; a second reload or an installation must not replace the instance meanwhile.
    @ObservationIgnored private var reloading: Set<String> = []

    /// `languages` are the user's languages, most preferred first (BCP 47, as in `Locale.preferredLanguages`):
    /// a mod is shown in the first of them it has a translation for, and its commands are told the first
    /// one as `TOOLSY_LOCALE`.
    public convenience init(
        directories: ToolsyDirectories = .user, privileged: any PrivilegedExecuting,
        languages: [String] = Locale.preferredLanguages
    ) {
        self.init(directories: directories, privileged: privileged, languages: languages, timing: EngineTiming())
    }

    init(directories: ToolsyDirectories, privileged: any PrivilegedExecuting, languages: [String] = [], timing: EngineTiming) {
        self.directories = directories
        self.privileged = privileged
        self.languages = languages
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
        post(.launch)
    }

    /// Stops every service and timer without running `disable`. Call when the app quits.
    public func shutdown() async {
        developerMode = false
        // A batch of folder changes being acted on must not load mods after this.
        await folderChangeWork?.value
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
            // What the confirmation shows is what the installed mod will be called.
            manifest: manifest.localized(for: languages),
            replacesInstalledMod: FileManager.default.fileExists(atPath: folder(of: manifest.id).path(percentEncoded: false)),
            installedVersion: mod(id: manifest.id)?.manifest.version,
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
        guard !reloading.contains(id) else {
            throw EngineError("\(prepared.manifest.name) is being reloaded.")
        }
        guard installing.insert(id).inserted else {
            throw EngineError("\(prepared.manifest.name) is already being installed.")
        }
        defer { installing.remove(id) }
        let previous = mod(id: id)
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
                _ = try? await replace(id, after: previous)
            } else {
                // The helper may have been installed on the way.
                await refreshAccess()
            }
            throw error
        }
        ModPackage.remove(prepared.staging)
        return try await replace(id, after: previous)
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
        if let mod = mod(id: id) {
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

    // MARK: - Mods

    /// The loaded mod with this id.
    public func mod(id: String) -> Mod? {
        modsByID[id]
    }

    /// Tells the mods that something happened to the Mac. Every mod that is on (or has no switch) and
    /// declares a command for `event` queues it with `TOOLSY_EVENT` naming the event, unless a run of that
    /// command is already waiting. A privileged one is skipped while the mod lacks administrator access.
    /// The store posts `launch` itself at the end of `start()`.
    public func post(_ event: ModSystemEvent) {
        for mod in mods {
            mod.handle(event)
        }
    }

    /// Reads a mod from its folder again and replaces the loaded instance, keeping its settings and switch
    /// position, as installing does once the files are in place; also loads a folder that was added by
    /// hand. A folder that does not load is listed in `loadProblems` and its error thrown. A folder that is
    /// gone takes the loaded mod with it; its saved settings stay.
    @discardableResult
    public func reload(_ id: String) async throws -> Mod {
        guard ModPayload.isSafeRelativePath(id), !id.contains("/") else {
            throw EngineError("\"\(id)\" is not the name of a mod folder.")
        }
        let previous = mod(id: id)
        let name = previous?.manifest.name ?? id
        guard !installing.contains(id), reloading.insert(id).inserted else {
            throw EngineError("\(name) is already being installed or reloaded.")
        }
        defer { reloading.remove(id) }
        if let previous, !previous.isActive {
            throw EngineError("\(name) is being removed.")
        }
        guard ModPackage.isDirectory(folder(of: id)) else {
            await drop(id)
            throw EngineError("The mods folder has no folder \"\(id)\".")
        }
        await previous?.close()
        return try await replace(id, after: previous)
    }

    /// Rate-limits a notification of a mod and hands it to `notificationHandler`.
    private func deliver(_ notification: ModNotification) {
        guard let notificationHandler else { return }
        switch notificationThrottle.admit(notification, timing: timing) {
        case .deliver:
            notificationHandler(notification)
        case .tooSoon:
            logger.notice("mod \(notification.modID, privacy: .public): notification dropped, the mod notified moments ago")
        case .repeated:
            logger.notice("mod \(notification.modID, privacy: .public): notification dropped, it repeats a recent one")
        }
    }

    // MARK: - Loading

    private func folder(of id: String) -> URL {
        directories.mods.appending(path: id, directoryHint: .isDirectory)
    }

    private func load(_ folder: URL, after predecessorWork: Task<Void, Never>? = nil) throws -> Mod {
        let data = try Data(contentsOf: folder.appending(path: ModManifest.fileName))
        let manifest = try ModManifest.load(from: data)
        try manifest.validateTemplatesAndExpressions()
        guard manifest.id == folder.lastPathComponent else {
            throw EngineError("the folder name does not match the mod's id \"\(manifest.id)\"")
        }
        return Mod(
            manifest: manifest.localized(for: languages),
            manifestDigest: SHA256.hash(data: data),
            folder: folder,
            saved: try PersistedState.load(for: manifest, from: directories),
            directories: directories,
            privileged: privileged,
            locale: languages.first,
            timing: timing,
            after: predecessorWork,
            accessMayHaveChanged: { [weak self] in
                Task { await self?.refreshAccess() }
            },
            notify: { [weak self] notification in
                self?.deliver(notification)
            }
        )
    }

    /// Replaces whatever the store holds for `id` (closed already, if anything) with a fresh load from disk
    /// and starts it. Its first command waits for the commands of `previous` to end.
    private func replace(_ id: String, after previous: Mod?) async throws -> Mod {
        mods.removeAll { $0.id == id }
        loadProblems.removeAll { $0.folder == id }
        let mod: Mod
        do {
            mod = try load(folder(of: id), after: previous?.unfinishedWork)
        } catch {
            loadProblems.append(LoadProblem(folder: id, message: error.localizedDescription))
            throw error
        }
        mods.append(mod)
        sortMods()
        if developerMode {
            filesSeenUntil[id] = Date()
        }
        await refreshAccess()
        mod.activate(panelVisible: isPanelVisible)
        return mod
    }

    /// Forgets a mod whose folder is gone without running any hook; its saved settings stay.
    private func drop(_ id: String) async {
        loadProblems.removeAll { $0.folder == id }
        guard let mod = mod(id: id), mod.isActive else { return }
        await mod.close()
        mods.removeAll { $0 === mod }
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

    // MARK: - Developer mode

    private func watchModsFolder() {
        do {
            try FileManager.default.createDirectory(at: directories.mods, withIntermediateDirectories: true)
            watchingSince = Date()
            watcher = try FolderWatcher(directories.mods, latency: 0.05) { [weak self] paths in
                self?.modsFolderChanged(paths)
            }
        } catch {
            logger.error("developer mode cannot watch the mods folder: \(error.localizedDescription)")
            developerMode = false
        }
    }

    private func stopWatchingModsFolder() {
        watcher = nil
        folderSettle?.cancel()
        folderSettle = nil
        pendingFolderChanges = [:]
        rescanPending = false
        filesSeenUntil = [:]
    }

    /// Collects changed paths (relative to the mods folder) until they settle.
    private func modsFolderChanged(_ paths: [String]) {
        for path in paths {
            let components = path.split(separator: "/", maxSplits: 1).map(String.init)
            guard let name = components.first else {
                // The mods folder itself, or changes FSEvents could not itemise: every mod folder is looked at.
                rescanPending = true
                continue
            }
            // Hidden entries are not mods, as at launch.
            guard !name.hasPrefix(".") else { continue }
            var changed = pendingFolderChanges[name, default: []]
            // `mod.json` is compared by digest, and Finder's metadata is not part of a mod.
            if components.count == 2, components[1] != ModManifest.fileName, !components[1].hasSuffix(".DS_Store") {
                changed.insert(components[1])
            }
            pendingFolderChanges[name] = changed
        }
        folderSettle?.cancel()
        folderSettle = Task { [weak self, settle = timing.folderSettle] in
            do {
                try await Task.sleep(for: settle)
            } catch {
                return
            }
            self?.actOnFolderChanges()
        }
    }

    private func actOnFolderChanges() {
        var changes = pendingFolderChanges
        pendingFolderChanges = [:]
        if rescanPending {
            rescanPending = false
            let present = (try? FileManager.default.contentsOfDirectory(atPath: directories.mods.path(percentEncoded: false))) ?? []
            for name in present.filter({ !$0.hasPrefix(".") }) + mods.map(\.id) + loadProblems.map(\.folder) where changes[name] == nil {
                changes[name] = []
            }
        }
        // One batch after another: acting on a change awaits closing and loading mods.
        let previous = folderChangeWork
        folderChangeWork = Task {
            await previous?.value
            for (name, paths) in changes.sorted(by: { $0.key < $1.key }) where developerMode {
                await folderChanged(name, paths: paths)
            }
        }
    }

    /// Acts on changes inside the mod folder `name`; `paths` are the changed files other than `mod.json`.
    private func folderChanged(_ name: String, paths: Set<String>) async {
        // The store's own installation and reloads see to these themselves.
        guard !installing.contains(name), !reloading.contains(name) else { return }
        let loaded = mod(id: name)
        let folder = folder(of: name)
        do {
            if !ModPackage.isDirectory(folder) {
                await drop(name)
            } else if let loaded {
                let manifest = try? Data(contentsOf: folder.appending(path: ModManifest.fileName))
                if manifest.map({ SHA256.hash(data: $0) }) != loaded.manifestDigest {
                    try await reload(name)
                } else if filesChanged(paths, in: folder, of: name) {
                    loaded.filesChanged()
                }
            } else {
                try await reload(name)
            }
        } catch {
            // A folder that does not load is listed in `loadProblems` by `reload`.
            logger.error("developer mode: \(name, privacy: .public) was not reloaded: \(error.localizedDescription)")
        }
    }

    /// Whether any of `paths` (relative to `folder`) is gone or was changed after the store last accounted
    /// for the files of mod `id`; advances that mark.
    private func filesChanged(_ paths: Set<String>, in folder: URL, of id: String) -> Bool {
        let seenUntil = max(filesSeenUntil[id] ?? .distantPast, watchingSince)
        var latest = seenUntil
        var changed = false
        for path in paths {
            var info = stat()
            guard lstat(folder.appending(path: path).path(percentEncoded: false), &info) == 0 else {
                // Removed or renamed away.
                changed = true
                continue
            }
            let time = Date(timeIntervalSince1970: TimeInterval(info.st_ctimespec.tv_sec) + TimeInterval(info.st_ctimespec.tv_nsec) / 1e9)
            if time > seenUntil {
                changed = true
                latest = max(latest, time)
            }
        }
        filesSeenUntil[id] = latest
        return changed
    }
}
