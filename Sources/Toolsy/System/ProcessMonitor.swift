import AppKit
import Observation

/// What a person thinks of as one app: every process inside one `.app` bundle (a browser and its
/// helpers) together with the XPC services macOS holds it responsible for, or a single process outside
/// any bundle.
struct ProcessGroup: Identifiable, Equatable {
    /// Stable while the group exists: the bundle's path, or the process's pid and start time.
    let id: String
    /// The running application's localised name, the bundle's display name, or the executable's name.
    var name: String
    var icon: NSImage?
    /// Physical footprint of all its processes in bytes, as Activity Monitor's Memory column.
    var memory: UInt64
    /// CPU use since the previous sample, in Activity Monitor's unit: 100 = one core fully busy.
    var cpu: Double
    var processCount: Int
    /// A regular app other than Toolsy and Finder, which `ProcessMonitor.quit(_:)` can ask to quit.
    var canQuit: Bool
    /// The process of the group's running application, if it has one.
    var applicationPID: pid_t?
}

/// The current user's apps by memory and CPU use, for the memory and CPU details.
///
/// Demand-driven like `SystemMonitor`: it samples only between `start()` and `stop()`, which are
/// counted, so several views can want it at once, and only while the panel is visible (a view in a
/// closed panel is not told it disappeared). Samples are taken off the main thread every `interval`
/// seconds; the groups of the last one are kept when sampling stops.
@Observable
final class ProcessMonitor {
    /// Every group of the latest sample, in no particular order. Empty until the first sample after
    /// the first `start()`.
    private(set) var groups: [ProcessGroup] = []

    @ObservationIgnored private let sampler = ProcessSampler()
    @ObservationIgnored private let interval: TimeInterval
    @ObservationIgnored private var demand = 0
    @ObservationIgnored private var isPanelVisible = false
    @ObservationIgnored private(set) var isSampling = false
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var sampling: Task<Void, Never>?
    /// Display name and icon of each group in the latest sample, by its id. They do not change while the
    /// group runs, and each lookup reads the file system; a new image every sample would also make the
    /// lists draw every icon again.
    @ObservationIgnored private var looks: [String: Look] = [:]

    init(panel: PanelState, interval: TimeInterval = 2.5) {
        self.interval = interval
        panel.addVisibilityHandler { [weak self] visible in
            self?.isPanelVisible = visible
            self?.updateSampling()
        }
    }

    /// The `count` groups that hold the most memory, largest first.
    func largest(_ count: Int) -> [ProcessGroup] {
        Array(groups.sorted { ($0.memory, $1.name) > ($1.memory, $0.name) }.prefix(count))
    }

    /// The `count` groups that used the most CPU, busiest first.
    func busiest(_ count: Int) -> [ProcessGroup] {
        Array(groups.sorted { ($0.cpu, $1.name) > ($1.cpu, $0.name) }.prefix(count))
    }

    func start() {
        demand += 1
        updateSampling()
    }

    func stop() {
        guard demand > 0 else {
            assertionFailure("ProcessMonitor.stop() without a matching start()")
            return
        }
        demand -= 1
        updateSampling()
    }

    /// Asks the group's application to quit, as choosing Quit in its menu does: it may ask about unsaved
    /// documents, or decline. Never forces it. Returns whether the request was sent.
    @discardableResult
    func quit(_ group: ProcessGroup) -> Bool {
        guard group.canQuit, let pid = group.applicationPID,
              let application = NSRunningApplication(processIdentifier: pid), Self.canQuit(application),
              // The app may have quit since the group was sampled and its pid been given to another.
              Self.groupID(of: application) == group.id else { return false }
        return application.terminate()
    }

    /// The id of the group a running application owns: its bundle (which is no group's id when the app is
    /// nested in another), or itself as a process when it has none.
    private static func groupID(of application: NSRunningApplication) -> String? {
        if let bundle = application.bundleURL?.path, bundle.hasSuffix(".app") {
            return bundle
        }
        return ProcessSampler.key(of: application.processIdentifier).map(id)
    }

    private static func id(of process: ProcessKey) -> String {
        "\(process.pid)-\(process.start)"
    }

    /// Which of the applications among a group's processes the group is named for and Quit would quit. For
    /// a bundle that is the app whose bundle it is, the one with a Dock icon if several are (an app and its
    /// login item). An app nested inside another (Simulator in Xcode) is part of the outer app's group and
    /// adds to its numbers, but neither names it nor is what the group's Quit means.
    static func owner<Application>(
        ofBundle path: String, among candidates: [Application],
        bundlePath: (Application) -> String?, isRegular: (Application) -> Bool
    ) -> Application? {
        let own = candidates.filter { bundlePath($0) == path }
        return own.first(where: isRegular) ?? own.first
    }

    // MARK: Sampling

    private func updateSampling() {
        let wanted = demand > 0 && isPanelVisible
        guard wanted != isSampling else { return }
        isSampling = wanted
        if wanted {
            // The first sample only records CPU times; the first groups follow shortly after it.
            sample(startingOver: true, thenWait: 0.5)
        } else {
            timer?.invalidate()
            timer = nil
            sampling?.cancel()
            sampling = nil
        }
    }

    private func sample(startingOver: Bool = false, thenWait delay: TimeInterval) {
        sampling = Task { [sampler] in
            let readings = await sampler.sample(startingOver: startingOver)
            guard !Task.isCancelled, isSampling else { return }
            if let readings { publish(readings) }
            sampling = nil
            schedule(after: delay)
        }
    }

    private func schedule(after delay: TimeInterval) {
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isSampling else { return }
                self.sample(thenWait: self.interval)
            }
        }
        timer.tolerance = delay * 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func publish(_ readings: [ProcessGroupReading]) {
        var applications: [pid_t: NSRunningApplication] = [:]
        for application in NSWorkspace.shared.runningApplications {
            applications[application.processIdentifier] = application
        }
        var seen: [String: Look] = [:]
        groups = readings.map { reading in
            let candidates = reading.pids.compactMap { applications[$0] }
            let id: String, look: Look, application: NSRunningApplication?
            switch reading.kind {
            case .bundle(let path):
                id = path
                application = Self.owner(ofBundle: path, among: candidates, bundlePath: { $0.bundleURL?.path },
                                         isRegular: { $0.activationPolicy == .regular })
                look = looks[id] ?? Look(name: Self.bundleName(atPath: path), icon: NSWorkspace.shared.icon(forFile: path))
                seen[id] = look
            case .process(let key, let executable):
                id = Self.id(of: key)
                application = candidates.first
                look = looks[id] ?? Look(name: (executable as NSString).lastPathComponent, icon: application?.icon)
                // Kept only once it has an icon: a process can become an application after it started.
                if look.icon != nil { seen[id] = look }
            }
            return ProcessGroup(
                id: id,
                name: application?.localizedName ?? look.name,
                icon: look.icon,
                memory: reading.memory,
                cpu: reading.cpu,
                processCount: reading.pids.count,
                canQuit: application.map(Self.canQuit) ?? false,
                applicationPID: application?.processIdentifier
            )
        }
        looks = seen
    }

    private struct Look {
        var name: String
        var icon: NSImage?
    }

    /// The name Finder shows for an app, without the extension it adds when it is set to show them all.
    static func bundleName(atPath path: String) -> String {
        let name = FileManager.default.displayName(atPath: path)
        return name.lowercased().hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    /// Regular apps only: background apps and agents have no Quit command a person would choose. Toolsy
    /// quits from its own menu, and Finder is relaunched by the system at once.
    static func canQuit(_ application: NSRunningApplication) -> Bool {
        application.activationPolicy == .regular
            && application.processIdentifier != getpid()
            && application.bundleIdentifier != "com.apple.finder"
            && !application.isTerminated
    }
}
