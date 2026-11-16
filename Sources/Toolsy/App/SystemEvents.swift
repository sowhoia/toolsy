import AppKit
import IOKit.ps
import os
import SystemConfiguration
import ToolsyShared

private let logger = Logger(subsystem: ToolsyPaths.bundleIdentifier, category: "system-events")

/// Where the Mac reports what one system event stands for.
protocol SystemEventSource: AnyObject {
    /// Starts observing and returns the condition now. `changed` runs on the main actor every time the system
    /// says the condition may have changed, with the condition then. An occurrence, such as waking, is an event
    /// every time: its condition is nil. A condition that cannot be read is logged and not reported (and nil
    /// from `start`, so the first one read is the baseline).
    func start(_ changed: @escaping (_ condition: String?) -> Void) -> String?
    /// Releases everything `start` created; `changed` is not called afterwards.
    func stop()
}

/// Turns what happens to the Mac into the system events mods declare (`ModStore.post`). It observes only the
/// events some loaded mod listens to and follows that set as mods come and go: with no such mod it holds no
/// observer at all. Events are posted on the main actor; what happens while the Mac sleeps is not replayed.
final class SystemEventMonitor {
    private let observed: () -> Set<ModSystemEvent>
    private let post: (ModSystemEvent) -> Void
    private let makeSource: @MainActor (ModSystemEvent) -> (any SystemEventSource)?
    private let networkSettle: Duration
    private var isRunning = false
    private(set) var sources: [ModSystemEvent: any SystemEventSource] = [:]
    /// The last condition each source reported, to post only real changes.
    private var conditions: [ModSystemEvent: String] = [:]
    /// The network reports a change as a burst of callbacks; the event waits until it has been quiet.
    private var settling: Task<Void, Never>?

    /// `observed` is read with observation tracking, so it is read again whenever what it reads changes.
    /// `makeSource` returns nil for an event the Mac has no source for (`launch`, which the store posts itself).
    init(observing observed: @escaping () -> Set<ModSystemEvent>,
         post: @escaping (ModSystemEvent) -> Void,
         networkSettle: Duration = .seconds(2),
         makeSource: @escaping @MainActor (ModSystemEvent) -> (any SystemEventSource)? = SystemEventMonitor.systemSource) {
        self.observed = observed
        self.post = post
        self.networkSettle = networkSettle
        self.makeSource = makeSource
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        follow()
    }

    func stop() {
        isRunning = false
        observe([])
    }

    /// Observes what `observed` asks for now, and again when it changes.
    private func follow() {
        guard isRunning else { return }
        let wanted = withObservationTracking(observed) { [weak self] in
            // Called before the change is made; read the new set once it is.
            Task { @MainActor in self?.follow() }
        }
        observe(wanted)
    }

    private func observe(_ wanted: Set<ModSystemEvent>) {
        for (event, source) in sources where !wanted.contains(event) {
            source.stop()
            sources[event] = nil
            conditions[event] = nil
            if event == .network {
                settling?.cancel()
                settling = nil
            }
        }
        for event in wanted where sources[event] == nil {
            guard let source = makeSource(event) else { continue }
            sources[event] = source
            conditions[event] = source.start { [weak self] condition in self?.report(condition, of: event) }
        }
    }

    private func report(_ condition: String?, of event: ModSystemEvent) {
        guard event == .network else { return changed(condition, of: event) }
        settling?.cancel()
        settling = Task { [weak self, networkSettle] in
            do { try await Task.sleep(for: networkSettle) } catch { return }  // cancelled by a later callback
            self?.changed(condition, of: event)
        }
    }

    private func changed(_ condition: String?, of event: ModSystemEvent) {
        guard let condition else { return post(event) }
        let previous = conditions.updateValue(condition, forKey: event)
        if let previous, previous != condition {
            post(event)
        }
    }

    /// The Mac's own source of `event`.
    static func systemSource(for event: ModSystemEvent) -> (any SystemEventSource)? {
        switch event {
        case .launch: nil
        case .wake: WakeSource()
        case .network: NetworkSource()
        case .power: PowerSource()
        }
    }
}

// MARK: - The Mac's sources

/// `NSWorkspace.didWakeNotification`, which the workspace posts once the Mac is awake again.
final class WakeSource: SystemEventSource {
    private var observer: (any NSObjectProtocol)?
    private var changed: ((String?) -> Void)?

    func start(_ changed: @escaping (String?) -> Void) -> String? {
        self.changed = changed
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.changed?(nil) }
        }
        return nil
    }

    func stop() {
        observer.map(NSWorkspace.shared.notificationCenter.removeObserver)
        observer = nil
        changed = nil
    }
}

/// The primary interface and the addresses of the interfaces, from the keys configd keeps in the dynamic store:
/// `State:/Network/Global/IPv4|6` name the primary interface and router, `State:/Network/Interface/<name>/IPv4|6`
/// hold each interface's addresses. Link-local IPv6 addresses do not count: AirDrop and Continuity bring their
/// interfaces (`awdl0`, `llw0`) up and down with nothing but those, many times an hour.
final class NetworkSource: SystemEventSource {
    private static let keys = ["State:/Network/Global/IPv4", "State:/Network/Global/IPv6"] as CFArray
    private static let patterns = ["State:/Network/Interface/[^/]+/IPv4", "State:/Network/Interface/[^/]+/IPv6"] as CFArray

    private var store: SCDynamicStore?
    private var changed: ((String?) -> Void)?

    func start(_ changed: @escaping (String?) -> Void) -> String? {
        self.changed = changed
        // The store keeps the source alive (`passRetained`, released with the store), so a callback already on
        // its way when `stop` releases the store still finds it.
        var context = SCDynamicStoreContext(version: 0, info: Unmanaged.passRetained(self).toOpaque(), retain: nil,
                                            release: releaseNetworkSource, copyDescription: nil)
        guard let store = SCDynamicStoreCreate(nil, "Toolsy" as CFString, { _, _, info in
            // Delivered on the main queue (SCDynamicStoreSetDispatchQueue below).
            let source = Unmanaged<NetworkSource>.fromOpaque(info!).takeUnretainedValue()  // the info set above
            MainActor.assumeIsolated {
                if let condition = source.condition() { source.changed?(condition) }
            }
        }, &context) else {
            logger.error("cannot observe the network: \(Self.lastError, privacy: .public)")
            return nil
        }
        self.store = store
        guard SCDynamicStoreSetNotificationKeys(store, Self.keys, Self.patterns),
              SCDynamicStoreSetDispatchQueue(store, .main) else {
            logger.error("cannot observe the network: \(Self.lastError, privacy: .public)")
            stop()
            return nil
        }
        return condition()
    }

    func stop() {
        if let store { SCDynamicStoreSetDispatchQueue(store, nil) }
        store = nil
        changed = nil
    }

    private static var lastError: String { String(cString: SCErrorString(SCError())) }

    /// One line per primary-interface key and per interface with addresses, sorted.
    private func condition() -> String? {
        guard let store else { return nil }
        guard let values = SCDynamicStoreCopyMultiple(store, Self.keys, Self.patterns) as? [String: [String: Any]] else {
            logger.error("cannot read the network state: \(Self.lastError, privacy: .public)")
            return nil
        }
        return values.compactMap { key, value -> String? in
            if key.hasPrefix("State:/Network/Global/") {
                return "\(key) \(value["PrimaryInterface"] ?? "") \(value["Router"] ?? "")"
            }
            let addresses = (value["Addresses"] as? [String] ?? []).filter { !$0.lowercased().hasPrefix("fe80:") }
            return addresses.isEmpty ? nil : "\(key) \(addresses.sorted().joined(separator: " "))"
        }.sorted().joined(separator: "\n")
    }
}

/// Releases the store's reference to its `NetworkSource`. Not a closure: one written in this file would be
/// isolated to the main actor, and the store is deallocated on a queue of its own.
nonisolated private func releaseNetworkSource(_ info: UnsafeRawPointer) {
    Unmanaged<NetworkSource>.fromOpaque(info).release()
}

/// `IOPSCreateLimitedPowerNotification`, which fires when the Mac changes between unlimited (adapter) and limited
/// (battery, UPS) power, and the providing source as the condition. Unlike `IOPSNotificationCreateRunLoopSource`
/// it does not fire for every change of the charge.
final class PowerSource: SystemEventSource {
    private var runLoopSource: CFRunLoopSource?
    private var changed: ((String?) -> Void)?

    func start(_ changed: @escaping (String?) -> Void) -> String? {
        self.changed = changed
        // Unretained: the run loop source is invalidated in `stop`, and run loop callbacks are synchronous on the
        // main thread, so none can arrive after it.
        guard let source = IOPSCreateLimitedPowerNotification({ info in
            let source = Unmanaged<PowerSource>.fromOpaque(info!).takeUnretainedValue()  // the context passed below
            MainActor.assumeIsolated {
                if let condition = PowerSource.providingSource() { source.changed?(condition) }
            }
        }, Unmanaged.passUnretained(self).toOpaque())?.takeRetainedValue() else {
            logger.error("cannot observe the power source")
            return nil
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        runLoopSource = source
        return Self.providingSource()
    }

    func stop() {
        if let runLoopSource { CFRunLoopSourceInvalidate(runLoopSource) }
        runLoopSource = nil
        changed = nil
    }

    /// "AC Power", "Battery Power" or "UPS Power".
    private static func providingSource() -> String? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else {
            logger.error("cannot read the power source")
            return nil
        }
        return type as String
    }
}
