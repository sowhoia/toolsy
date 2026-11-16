import CryptoKit
import Foundation
import Observation
import ToolsyShared

/// Whether a mod can run its privileged commands, and if not, what is missing.
public enum AdministratorAccess: Sendable, Equatable {
    /// The mod has no privileged commands.
    case notNeeded
    /// The helper is not installed (`.notInstalled`) or must be updated (`.needsUpdate`).
    case helperUnavailable(HelperStatus)
    /// The helper holds no approval of the mod's current files; only installing the mod again from a
    /// package gives it one. `modified`: the helper approved other files under this id, so the installed
    /// ones were changed after the mod was installed.
    case notApproved(modified: Bool)
    case granted
}

/// One installed mod: its manifest, its state and everything it runs. Obtained from `ModStore.mods`.
///
/// Commands of a mod run strictly one after another in the order they were started. After the mod was
/// removed or replaced (or the store shut down) every operation is ignored.
@MainActor @Observable
public final class Mod: Identifiable {
    public let manifest: ModManifest
    /// The installed copy, `<directories.mods>/<id>/`.
    public let folder: URL
    /// Settings and live state in one flat object; the page is a function of this and `manifest`.
    public private(set) var state: ModState
    /// From a call to `setEnabled` until its hooks have finished. The switch should be inert meanwhile.
    public private(set) var isSwitching = false
    public private(set) var access: AdministratorAccess
    /// The newest runs of the mod's commands and the starts and exits of its service, oldest first; at most
    /// 20. A property of its own, so recording a run does not re-render what reads `state`.
    public private(set) var recentRuns: [CommandRun] = []

    public nonisolated var id: String { manifest.id }

    /// Whether the mod has a main switch; mods without one are passive widgets.
    public var hasSwitch: Bool { manifest.lifecycle.hasToggle }
    public var isEnabled: Bool { state[ReservedStateKey.enabled]?.boolValue ?? false }
    public var status: String? { state[ReservedStateKey.status]?.stringValue }
    public var level: ModLevel? { state[ReservedStateKey.level]?.stringValue.flatMap(ModLevel.init(rawValue:)) }
    public var error: String? { state[ReservedStateKey.error]?.stringValue }

    /// Names of the commands executing or waiting for their turn; buttons show a spinner for them.
    public var runningCommands: Set<String> {
        Set(([currentJob].compactMap(\.self) + queue).compactMap(\.commandName))
    }

    private enum Phase {
        case active
        /// Removal hooks are running: no schedule, no automatic refresh, no service.
        case removing
        /// Replaced, removed or shut down.
        case closed
    }

    private enum Work: Equatable {
        case command(String, event: ModEvent, key: String?, value: JSONValue?)
        case switchOn, switchOff
    }

    /// Who reported the current `error`; decides what may clear it (MOD_FORMAT.md, "Errors").
    private enum ErrorSource {
        /// A command the user started: the switch, a button, a bound control.
        case user
        /// The automatic refresh.
        case refresh
        case service
        /// A command started by a system event (`lifecycle.events`).
        case event
    }

    private struct Job {
        var work: Work
        /// Commands the user did not start skip silently when access is missing instead of raising an error.
        var origin = ErrorSource.user
        var waiters: [CheckedContinuation<Bool, Never>] = []

        var commandName: String? {
            if case .command(let name, _, _, _) = work { name } else { nil }
        }
    }

    private var phase = Phase.active
    private var queue: [Job] = []
    private var currentJob: Job?
    /// Recorded samples per chart-bound key; see `history(of:)`.
    private var histories: [String: [Double]] = [:]
    @ObservationIgnored private var errorSource: ErrorSource?
    /// Templates and expressions of the manifest by source text, parsed on first use. Views render them on
    /// every change of state; nil marks text that does not parse.
    @ObservationIgnored private var templates: [String: ModTemplate?] = [:]
    @ObservationIgnored private var expressions: [String: ModExpression?] = [:]
    @ObservationIgnored private var runCount = 0

    /// SHA-256 of the `mod.json` bytes this instance was loaded from.
    let manifestDigest: SHA256.Digest
    @ObservationIgnored private let directories: ToolsyDirectories
    @ObservationIgnored private let privileged: any PrivilegedExecuting
    /// The user's first language, which commands are told as `TOOLSY_LOCALE`.
    @ObservationIgnored private let locale: String?
    @ObservationIgnored private let timing: EngineTiming
    @ObservationIgnored private let accessMayHaveChanged: @MainActor () -> Void
    @ObservationIgnored private let notify: @MainActor (ModNotification) -> Void
    /// The commands of the instance this one replaced. They may still be finishing (a privileged command
    /// cannot be stopped), and commands of a mod never overlap, so this instance's first command waits.
    @ObservationIgnored private var predecessorWork: Task<Void, Never>?
    /// Chart-bound key → the largest `points` among the charts showing it.
    @ObservationIgnored private let historyLimits: [String: Int]
    /// `(key, command)` of live sliders, whose pending runs collapse to the latest value.
    @ObservationIgnored private let liveSliders: Set<[String]>
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var isPanelVisible = false
    @ObservationIgnored private var refreshTimer: Task<Void, Never>?

    @ObservationIgnored private var service: (process: ServiceProcess, events: Task<Void, Never>, started: ContinuousClock.Instant)?
    /// A scheduled (re)start of the service: crash backoff or the settings debounce.
    @ObservationIgnored private var pendingServiceStart: Task<Void, Never>?
    /// The stop in progress, so concurrent stoppers all wait for the process to be gone.
    @ObservationIgnored private var serviceTermination: Task<Void, Never>?
    @ObservationIgnored private var nextBackoff: Double = 1
    /// Delays (unscaled seconds) of the recent crash restarts, newest last; lets tests observe the backoff.
    @ObservationIgnored private(set) var restartDelays: [Double] = []
    /// When the last restart for changed files happened or is scheduled to happen.
    @ObservationIgnored private var lastFileRestart: ContinuousClock.Instant?

    init(
        manifest: ModManifest,
        manifestDigest: SHA256.Digest,
        folder: URL,
        saved: PersistedState,
        directories: ToolsyDirectories,
        privileged: any PrivilegedExecuting,
        locale: String? = nil,
        timing: EngineTiming,
        after predecessorWork: Task<Void, Never>? = nil,
        accessMayHaveChanged: @escaping @MainActor () -> Void,
        notify: @escaping @MainActor (ModNotification) -> Void
    ) {
        self.manifest = manifest
        self.manifestDigest = manifestDigest
        self.folder = folder
        self.directories = directories
        self.privileged = privileged
        self.locale = locale
        self.timing = timing
        self.predecessorWork = predecessorWork
        self.accessMayHaveChanged = accessMayHaveChanged
        self.notify = notify
        var state = saved.settings
        state[ReservedStateKey.enabled] = .bool(saved.enabled)
        self.state = state
        access = manifest.requiresPrivileges ? .helperUnavailable(.notInstalled) : .notNeeded

        var limits: [String: Int] = [:]
        var live: Set<[String]> = []
        for control in manifest.allControls {
            switch control.kind {
            case .chart(let chart):
                for series in chart.series {
                    limits[series.bind] = max(limits[series.bind] ?? 0, chart.points)
                }
            case .slider(let slider) where slider.live:
                if let command = slider.command { live.insert([slider.bind, command]) }
            default:
                break
            }
        }
        for widget in manifest.widgets {
            guard let chart = widget.chart else { continue }
            for series in chart.series {
                limits[series.bind] = max(limits[series.bind] ?? 0, chart.points)
            }
        }
        historyLimits = limits
        liveSliders = live
    }

    // MARK: - Operations

    /// Flips the main switch: `on` runs `enable` and then starts the service; off stops the service and
    /// runs `disable`. Returns when done. Ignored without a switch, while a switch change is in flight,
    /// or when the switch already is in that position.
    public func setEnabled(_ on: Bool) async {
        guard phase == .active, hasSwitch, !isSwitching, on != isEnabled else { return }
        isSwitching = true
        await submit(on ? .switchOn : .switchOff)
    }

    /// Stores a control's new value. A declared setting is saved and restarts the service; with `command`
    /// that command runs next with `TOOLSY_KEY`/`TOOLSY_VALUE` set. A `null` value removes the key.
    /// The keys the host manages (`enabled`, `status`, `level`, `error`) are not bindable and are ignored.
    public func setValue(_ value: JSONValue, for key: String, command: String? = nil) {
        guard phase == .active, !ReservedStateKey.all.contains(key) else { return }
        merge([key: value])
        if let command {
            enqueue(Job(work: .command(command, event: .command, key: key, value: value)))
        }
    }

    /// Runs a command as a button or list row does; returns when it has finished.
    public func run(_ command: String, key: String? = nil, value: JSONValue? = nil) async {
        guard phase == .active else { return }
        await submit(.command(command, event: .command, key: key, value: value))
    }

    public func dismissError() {
        setState(ReservedStateKey.error, to: nil)
        errorSource = nil
    }

    /// Renders a template of this mod's manifest against the current state.
    public func render(_ template: String) -> String {
        let compiled = templates[template] ?? {
            // Manifests are checked at install and load, so their templates always parse; other text stays as is.
            let compiled = try? ModTemplate(template)
            templates[template] = compiled
            return compiled
        }()
        return compiled?.render(state) ?? template
    }

    /// Evaluates a `when` / `disabled` expression of this mod's manifest against the current state.
    public func evaluate(_ expression: String) -> Bool {
        let compiled = expressions[expression] ?? {
            // Checked at install and load like templates; anything that does not parse counts as false.
            let compiled = try? ModExpression(expression)
            expressions[expression] = compiled
            return compiled
        }()
        return compiled?.evaluate(state) ?? false
    }

    /// What a chart series bound to `key` plots: an array of numbers held by the key as is, otherwise the
    /// numbers patches delivered for it, oldest first, at most the largest `points` of the charts showing it.
    public func history(of key: String) -> [Double] {
        if let array = state[key]?.arrayValue {
            return array.compactMap(\.numberValue)
        }
        return histories[key] ?? []
    }

    // MARK: - Driven by the store

    /// Starts what an enabled mod keeps running: the service and a background refresh schedule.
    func activate(panelVisible: Bool) {
        isPanelVisible = panelVisible
        reconcile()
    }

    /// Queues the command the mod runs for `event`, if it has one and is on (a mod without a switch always
    /// is; one whose switch is changing is neither). A run of that command already waiting is enough; a
    /// privileged one is skipped silently while administrator access is missing.
    func handle(_ event: ModSystemEvent) {
        guard phase == .active, !hasSwitch || (isEnabled && !isSwitching), let name = manifest.lifecycle.events[event] else { return }
        if manifest.commands[name]?.privileged == true, missingAccess != nil { return }
        guard !queue.contains(where: { $0.commandName == name }) else { return }
        enqueue(Job(work: .command(name, event: event.commandEvent, key: nil, value: nil), origin: .event))
    }

    /// Developer mode saw files of the mod other than `mod.json` change: a running service restarts so it
    /// runs the new code, at most once per `fileRestartInterval`.
    func filesChanged() {
        guard phase == .active, service != nil || pendingServiceStart != nil else { return }
        let now = timing.now()
        // A restart still to come starts the service after these changes too.
        if let last = lastFileRestart, last > now { return }
        let wait = lastFileRestart.map { max(.zero, timing.fileRestartInterval - $0.duration(to: now)) } ?? .zero
        lastFileRestart = now + wait
        restartService(after: wait)
    }

    /// Whether the mod is in normal operation: not being removed, not closed.
    var isActive: Bool { phase == .active }

    /// The commands still running or waiting, so a successor can wait for them; nil when there are none.
    var unfinishedWork: Task<Void, Never>? { worker }

    func panelVisibilityChanged(_ visible: Bool) {
        isPanelVisible = visible
        if visible {
            requestRefresh()
        }
        updateRefreshSchedule()
    }

    func updateAccess(helperStatus: HelperStatus, approvedDigest: String?) async {
        guard manifest.requiresPrivileges else {
            access = .notNeeded
            return
        }
        guard helperStatus == .ready else {
            access = .helperUnavailable(helperStatus)
            return
        }
        guard let approvedDigest else {
            access = .notApproved(modified: false)
            return
        }
        let folder = folder
        do {
            let digest = try await Task.detached { try ModPayload(directory: folder).digest }.value
            access = digest == approvedDigest ? .granted : .notApproved(modified: true)
        } catch {
            // Files that cannot even be read are not the approved ones.
            logger.error("mod \(self.id, privacy: .public): cannot read the installed files: \(error.localizedDescription)")
            access = .notApproved(modified: true)
        }
    }

    /// Switches the mod off (running `disable`) and runs `uninstall`. Throws the mod's error when a hook
    /// fails, unless `force`; the mod then stays as it was.
    func runRemovalHooks(force: Bool) async throws {
        guard phase == .active else {
            throw EngineError("\(manifest.name) is already being removed.")
        }
        phase = .removing
        updateRefreshSchedule()
        // Queued behind any switch change still in flight, so a mod being switched on is switched off again.
        if hasSwitch {
            isSwitching = true
            if await !submit(.switchOff), !force {
                throw abortRemoval()
            }
        }
        if let uninstall = manifest.lifecycle.uninstall,
           await !submit(.command(uninstall, event: .uninstall, key: nil, value: nil)), !force {
            throw abortRemoval()
        }
    }

    /// Returns a mod whose removal failed to normal operation and gives the reason.
    func abortRemoval() -> EngineError {
        phase = .active
        reconcile()
        return EngineError(error ?? "\(manifest.name) could not be removed.")
    }

    /// Stops everything without running any hook: on quit, before the files are replaced, after removal.
    func close() async {
        phase = .closed
        refreshTimer?.cancel()
        refreshTimer = nil
        let pending = queue
        queue = []
        for job in pending {
            job.waiters.forEach { $0.resume(returning: false) }
        }
        // Cancelling the worker kills the command it is running.
        worker?.cancel()
        await stopService()
    }

    // MARK: - Queue

    @discardableResult
    private func submit(_ work: Work) async -> Bool {
        await withCheckedContinuation { continuation in
            enqueue(Job(work: work, waiters: [continuation]))
        }
    }

    private func enqueue(_ job: Job) {
        guard phase != .closed else {
            job.waiters.forEach { $0.resume(returning: false) }
            return
        }
        if case .command(let name, .command, let key?, _) = job.work, liveSliders.contains([key, name]),
           let last = queue.indices.last, case .command(let pendingName, .command, let pendingKey, _) = queue[last].work,
           pendingName == name, pendingKey == key {
            queue[last].work = job.work
            queue[last].waiters += job.waiters
            return
        }
        queue.append(job)
        if worker == nil {
            worker = Task { await drain() }
        }
    }

    private func drain() async {
        if let predecessorWork {
            await predecessorWork.value
            self.predecessorWork = nil
        }
        while !queue.isEmpty, !Task.isCancelled {
            let job = queue.removeFirst()
            currentJob = job
            let succeeded = await perform(job)
            currentJob = nil
            job.waiters.forEach { $0.resume(returning: succeeded) }
            if job.commandName != refreshCommand {
                requestRefresh()
            }
        }
        worker = nil
    }

    private func perform(_ job: Job) async -> Bool {
        switch job.work {
        case .command(let name, let event, let key, let value):
            await execute(name, event: event, key: key, value: value, origin: job.origin) != nil
        case .switchOn:
            await switchOn()
        case .switchOff:
            await switchOff()
        }
    }

    private func switchOn() async -> Bool {
        defer {
            isSwitching = false
            reconcile()
        }
        if let enable = manifest.lifecycle.enable {
            guard let patch = await execute(enable, event: .enable) else {
                setSwitch(false)
                return false
            }
            // The command may correct the switch itself.
            if patch[ReservedStateKey.enabled] != nil { return true }
        }
        setSwitch(true)
        return true
    }

    private func switchOff() async -> Bool {
        defer {
            isSwitching = false
            reconcile()
        }
        guard isEnabled else { return true }
        await stopService()
        if let disable = manifest.lifecycle.disable {
            // On failure the switch stays on and `reconcile` brings the service back.
            guard let patch = await execute(disable, event: .disable) else { return false }
            if patch[ReservedStateKey.enabled] != nil { return true }
        }
        setSwitch(false)
        return true
    }

    private func setSwitch(_ on: Bool) {
        merge([ReservedStateKey.enabled: .bool(on)])
    }

    // MARK: - Commands

    /// Runs one command, applies its outcome and records the run. Returns the applied patch, or nil when it
    /// failed or did not run.
    private func execute(_ name: String, event: ModEvent, key: String? = nil, value: JSONValue? = nil, origin: ErrorSource = .user) async -> ModState? {
        let started = Date()
        let clock = ContinuousClock.now
        func record(_ outcome: CommandRun.Outcome, standardError: Data = Data(), outputWasPatch: Bool = false) {
            recordRun(name, event: event, started: started, duration: clock.duration(to: .now), outcome: outcome,
                      standardError: standardError, outputWasPatch: outputWasPatch)
        }
        guard let command = manifest.commands[name] else {
            let message = "\(manifest.name) has no command \"\(name)\"."
            fail(message, command: name, detail: "undefined command", from: origin)
            record(.couldNotStart(message))
            return nil
        }
        let input = CommandInput(event: event, command: name, key: key, value: value, state: state, locale: locale)
        let result: CommandResult
        do {
            if command.privileged {
                if let missing = missingAccess {
                    if origin == .user {
                        fail(missing.localizedDescription, command: name, detail: "no administrator access", from: origin)
                    }
                    record(.refused)
                    return nil
                }
                result = try await privileged.run(modID: id, command: name, input: input)
            } else {
                result = try await ProcessRunner.run(request(for: command, input: input))
            }
        } catch is CancellationError {
            return nil
        } catch let failure as PrivilegedError {
            fail(failure.localizedDescription, command: name, detail: "administrator helper error", from: origin)
            record(.couldNotStart(failure.localizedDescription))
            accessMayHaveChanged()
            return nil
        } catch {
            fail(error.localizedDescription, command: name, detail: "could not start", from: origin)
            record(.couldNotStart(error.localizedDescription))
            return nil
        }
        let object = CommandOutput(result.stdout).patch
        let outcome: CommandRun.Outcome = result.timedOut ? .timedOut : result.succeeded ? .succeeded : .failed(exitCode: result.exitCode)
        record(outcome, standardError: result.stderr, outputWasPatch: command.capture == nil && object != nil)
        return apply(result, object: object, of: command, named: name, from: origin)
    }

    private var missingAccess: PrivilegedError? {
        switch access {
        case .granted, .notNeeded: nil
        case .helperUnavailable(let status): .helperUnavailable(status)
        case .notApproved: .notApproved(modID: id)
        }
    }

    /// How an unprivileged command or the service is started.
    private func request(for command: ModCommand, input: CommandInput) throws -> ProcessRunner.Request {
        try command.request(modID: id, modDirectory: folder, dataDirectory: directories.data.appending(path: id, directoryHint: .isDirectory),
                            input: input)
    }

    private func apply(_ result: CommandResult, object: ModState?, of command: ModCommand, named name: String, from source: ErrorSource) -> ModState? {
        guard result.succeeded else {
            fail(result.failureMessage(command: name, timeout: command.timeout), command: name,
                 detail: result.failureDetail(timeout: command.timeout), from: source)
            return nil
        }
        var patch: ModState
        if let capture = command.capture {
            patch = [capture: .string(String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))]
        } else {
            patch = object ?? [:]
        }
        settleError(in: &patch, reportedBy: source)
        merge(patch)
        return patch
    }

    private func report(_ message: String, from source: ErrorSource) {
        setState(ReservedStateKey.error, to: .string(message))
        errorSource = source
    }

    /// Adds a run to `recentRuns`, dropping the oldest beyond `CommandRun.kept`.
    private func recordRun(_ command: String, event: ModEvent, started: Date = Date(), duration: Duration = .zero,
                           outcome: CommandRun.Outcome, standardError: Data = Data(), outputWasPatch: Bool = false) {
        // A closed mod is no longer shown; its late results belong to nobody.
        guard phase != .closed else { return }
        runCount += 1
        let run = CommandRun(id: runCount, command: command, event: event, started: started, duration: duration, outcome: outcome,
                             standardError: standardError, outputWasPatch: outputWasPatch)
        recentRuns = Array((recentRuns + [run]).suffix(CommandRun.kept))
    }

    /// A successful report decides what happens to the error: a patch that names `error` sets or clears
    /// it; otherwise the error goes away only if the user started this run or its own source raised it.
    /// That keeps the refresh following every command from wiping the reason a button just failed.
    private func settleError(in patch: inout ModState, reportedBy source: ErrorSource) {
        if let reported = patch[ReservedStateKey.error] {
            if reported.stringValue?.isEmpty == false {
                errorSource = source
            } else {
                // Anything but a message means there is no error.
                patch[ReservedStateKey.error] = .null
                errorSource = nil
            }
        } else if errorSource != nil, source == .user || source == errorSource {
            patch[ReservedStateKey.error] = .null
            errorSource = nil
        }
    }

    private func fail(_ message: String, command: String, detail: String, from source: ErrorSource) {
        report(message, from: source)
        logger.error("mod \(self.id, privacy: .public): command \(command, privacy: .public) failed: \(detail, privacy: .public)")
    }

    // MARK: - State

    /// Applies a patch. Keys whose value does not change are not written, so an identical patch leaves
    /// `state` untouched and re-renders nothing; chart histories still record its numbers.
    private func merge(_ patch: ModState, fromService: Bool = false) {
        // A late result of a replaced mod must not overwrite the state file its successor uses, nor notify.
        guard phase != .closed else { return }
        if let request = patch[ReservedStateKey.notify] {
            announce(request)
        }
        let wasEnabled = isEnabled
        var settingsChanged = false
        for (key, value) in patch where ModManifest.isValidKey(key) && key != ReservedStateKey.notify {
            // The switch position must stay a boolean.
            if key == ReservedStateKey.enabled, value.boolValue == nil { continue }
            // A text field committing an unchanged value must not restart the service.
            if setState(key, to: value == .null ? JSONValue?.none : value), manifest.settings[key] != nil {
                settingsChanged = true
            }
            record(value, for: key)
        }
        if settingsChanged || isEnabled != wasEnabled {
            save()
        }
        // A service restarting for its own patches would restart forever.
        if settingsChanged, !fromService {
            restartServiceSoon()
        }
        if isEnabled != wasEnabled {
            reconcile()
        }
    }

    /// Writes one key of `state` only if its value changes, since every write invalidates the views reading
    /// `state`. Returns whether it changed.
    @discardableResult
    private func setState(_ key: String, to value: JSONValue?) -> Bool {
        guard state[key] != value else { return false }
        state[key] = value
        return true
    }

    /// Hands a `notify` request to the store, which rate-limits and delivers it.
    private func announce(_ request: JSONValue) {
        guard let notification = ModNotification(request, modID: id, modName: manifest.name) else {
            // Blank text asks for nothing; a value of another shape is the mod's mistake.
            if request.stringValue == nil, request.objectValue == nil, request != .null {
                logger.notice("mod \(self.id, privacy: .public): ignored a notify value that is neither text nor an object")
            }
            return
        }
        notify(notification)
    }

    private func record(_ value: JSONValue, for key: String) {
        guard let limit = historyLimits[key], let number = value.numberValue else { return }
        var samples = histories[key, default: []]
        samples.append(number)
        if samples.count > limit {
            samples.removeFirst(samples.count - limit)
        }
        histories[key] = samples
    }

    private func save() {
        let settings = state.filter { manifest.settings[$0.key] != nil }
        do {
            try PersistedState(enabled: isEnabled, settings: settings).save(for: id, in: directories)
        } catch {
            report("Settings could not be saved: \(error.localizedDescription)", from: .user)
            logger.error("mod \(self.id, privacy: .public): settings could not be saved: \(error.localizedDescription)")
        }
    }

    /// Brings the service and the refresh schedule in line with the switch, the panel and the phase.
    private func reconcile() {
        updateRefreshSchedule()
        // Switch changes start and stop the service themselves and reconcile when done.
        guard manifest.lifecycle.service != nil, !isSwitching else { return }
        if wantsService {
            startServiceIfNeeded()
        } else if service != nil || pendingServiceStart != nil {
            Task { await stopService() }
        }
    }

    // MARK: - Refresh

    private var refreshCommand: String? { manifest.lifecycle.refresh?.command }

    /// Queues the refresh command unless one is already queued or running.
    private func requestRefresh() {
        guard phase == .active, let name = refreshCommand, let command = manifest.commands[name] else { return }
        // Without access the command cannot run; a schedule must not raise the same error every few seconds.
        if command.privileged, missingAccess != nil { return }
        guard currentJob?.commandName != name, !queue.contains(where: { $0.commandName == name }) else { return }
        enqueue(Job(work: .command(name, event: .refresh, key: nil, value: nil), origin: .refresh))
    }

    private func updateRefreshSchedule() {
        let interval: Double? = {
            guard phase == .active, let refresh = manifest.lifecycle.refresh, let every = refresh.every else { return nil }
            let inBackground = refresh.background && (!hasSwitch || isEnabled)
            return isPanelVisible || inBackground ? every : nil
        }()
        guard let interval else {
            refreshTimer?.cancel()
            refreshTimer = nil
            return
        }
        guard refreshTimer == nil else { return }
        let period = timing.duration(interval)
        refreshTimer = Task { [weak self] in
            while true {
                do {
                    try await Task.sleep(for: period)
                } catch {
                    return
                }
                guard let self else { return }
                requestRefresh()
            }
        }
    }

    // MARK: - Service

    private var wantsService: Bool {
        manifest.lifecycle.service != nil && phase == .active && isEnabled && !isSwitching
    }

    /// `restart`: Toolsy itself starts the service again (after a crash, or for changed settings or files).
    private func startServiceIfNeeded(restart: Bool = false) {
        guard wantsService, service == nil, pendingServiceStart == nil,
              let name = manifest.lifecycle.service, let command = manifest.commands[name] else { return }
        let started = ContinuousClock.now
        do {
            let request = try request(for: command, input: CommandInput(event: .service, command: name, state: state, locale: locale))
            let process = try ServiceProcess(
                executable: request.executable, arguments: request.arguments, environment: request.environment,
                directory: folder, input: request.stdin
            )
            let events = Task { [weak self] in
                for await event in process.events {
                    switch event {
                    case .line(let line):
                        self?.serviceWrote(line)
                    case .exit(let status, let errorTail):
                        await self?.serviceExited(process, status: status, errorTail: errorTail)
                    }
                }
            }
            service = (process, events, started)
            recordService(process)
            recordRun(name, event: .service, outcome: restart ? .restarted : .started)
        } catch {
            recordRun(name, event: .service, outcome: .couldNotStart(error.localizedDescription))
            serviceFailed(error.localizedDescription, detail: "could not start", ranFor: .zero)
        }
    }

    private func serviceWrote(_ line: Data) {
        guard phase == .active, var patch = CommandOutput(line).patch else { return }
        settleError(in: &patch, reportedBy: .service)
        merge(patch, fromService: true)
    }

    private func serviceExited(_ process: ServiceProcess, status: Int32, errorTail: Data) async {
        // A service stopped on purpose is no longer the current one.
        guard let current = service, current.process === process, let name = manifest.lifecycle.service else { return }
        service = nil
        let ranFor = current.started.duration(to: .now)
        recordRun(name, event: .service, started: Date(timeIntervalSinceNow: -(ranFor / .seconds(1))), duration: ranFor,
                  outcome: .exited(status: status), standardError: errorTail)
        // Whatever it started dies with it.
        await process.terminateGroup(grace: timing.killGrace)
        forgetService(process)
        // Stopped, restarted or closed meanwhile: this exit no longer decides anything.
        guard phase == .active, service == nil, pendingServiceStart == nil else { return }
        if status == 0 {
            logger.info("mod \(self.id, privacy: .public): service exited with status 0, switching off")
            await setEnabled(false)
            return
        }
        serviceFailed(CommandResult(exitCode: status, stderr: errorTail).serviceFailureMessage, detail: "exit status \(status)", ranFor: ranFor)
    }

    /// Shows why the service is down and restarts it after 1, 2, 4 … 60 s; a healthy run resets the delay.
    private func serviceFailed(_ message: String, detail: String, ranFor: Duration) {
        report(message, from: .service)
        if ranFor >= timing.healthyRun {
            nextBackoff = 1
        }
        let delay = nextBackoff
        nextBackoff = min(nextBackoff * 2, 60)
        restartDelays = Array((restartDelays + [delay]).suffix(16))
        logger.error("mod \(self.id, privacy: .public): service failed (\(detail, privacy: .public)), restarting in \(delay) s")
        let wait = timing.duration(delay)
        pendingServiceStart = Task { [weak self] in
            do {
                try await Task.sleep(for: wait)
            } catch {
                return
            }
            self?.pendingServiceStart = nil
            self?.startServiceIfNeeded(restart: true)
        }
    }

    /// Settings changed: restart a running (or scheduled) service once the changes settle.
    private func restartServiceSoon() {
        restartService(after: timing.settingsDebounce)
    }

    /// Restarts a running (or scheduled) service after `delay`, replacing any start already scheduled.
    private func restartService(after delay: Duration) {
        guard service != nil || pendingServiceStart != nil else { return }
        pendingServiceStart?.cancel()
        pendingServiceStart = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            await self?.terminateService()
            // A stop requested meanwhile cancelled this restart.
            guard !Task.isCancelled else { return }
            self?.pendingServiceStart = nil
            self?.startServiceIfNeeded(restart: true)
        }
    }

    /// Stops the service and cancels any scheduled start; returns when its process group is gone.
    private func stopService() async {
        pendingServiceStart?.cancel()
        pendingServiceStart = nil
        await terminateService()
    }

    private func terminateService() async {
        if let current = service {
            service = nil
            let grace = timing.killGrace
            serviceTermination = Task {
                await current.process.terminateGroup(grace: grace)
                await current.events.value
                forgetService(current.process)
            }
        }
        await serviceTermination?.value
    }

    /// Notes which process the service is, so a later launch can stop it should this one die first.
    private func recordService(_ process: ServiceProcess) {
        do {
            // Nil when the process is already gone; its exit event then cleans up as usual.
            try ServiceRecord(pid: process.processIdentifier)?.save(for: id, in: directories)
        } catch {
            // The service works without the record; only the cleanup after a crash of Toolsy is lost.
            logger.error("mod \(self.id, privacy: .public): cannot record the service process: \(error.localizedDescription)")
        }
    }

    /// Removes the record of `process` unless a newer service has replaced it meanwhile.
    private func forgetService(_ process: ServiceProcess) {
        guard service == nil || service?.process === process else { return }
        ServiceRecord.remove(for: id, in: directories)
    }
}
