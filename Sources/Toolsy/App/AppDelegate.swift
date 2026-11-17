import AppKit
import ToolsyEngine
import ToolsyHelperClient
import ToolsyShared

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Navigation and visibility of the panel. Cheap, so it exists from launch and later parts
    /// of the app (the mod engine) can register visibility handlers before the panel exists.
    let panelState = PanelState()
    let mods: ModsModel
    let loginItem: LoginItem
    let dashboard: DashboardStore
    let processes: ProcessMonitor
    let memoryOptimizer: MemoryOptimizer
    /// Mods' system events and notifications.
    let systemEvents: SystemEventMonitor
    let notifier: ModNotifier
    /// Toolsy's own preferences, its alerts about the Mac, its check for updates and their installation.
    let settings: AppSettings
    let alerts: SystemAlerts
    let updates: UpdateChecker
    let installer: UpdateInstaller

    private let options: LaunchOptions
    private var statusItem: NSStatusItem?
    /// Created on first open: the window, the SwiftUI tree and the system monitor cost nothing
    /// until the user asks for them.
    private(set) var panelController: PanelController?
    private var handOffObserver: NSObjectProtocol?
    /// `--page` applies to the first time the panel opens.
    private var pendingStartPage: PanelPage?
    private var signalSources: [any DispatchSourceSignal] = []
    private var isTerminating = false
    #if DEBUG
    /// The stand-in helper of a debug run, which the debug script drives.
    private(set) var simulatedHelper: SimulatedHelper?
    /// Where the menu bar icon is, for the debug script's captures of it.
    var statusItemFrame: NSRect? { statusItem?.button?.window?.frame }
    var statusItemWindow: NSWindow? { statusItem?.button?.window }
    #endif

    init(options: LaunchOptions) {
        self.options = options
        pendingStartPage = options.startPage
        let directories = options.directories
        let privileged: any PrivilegedExecuting & SystemMaintaining
        #if DEBUG
        // A run on scratch data never talks to the real helper, so it can never install it.
        if options.simulateHelper || options.dataRoot != nil {
            let simulated = SimulatedHelper(store: directories.root.appending(path: "SimulatedHelper", directoryHint: .isDirectory))
            simulatedHelper = simulated
            privileged = simulated
        } else {
            privileged = HelperClient()
        }
        #else
        privileged = HelperClient()
        #endif
        let store = ModStore(directories: directories, privileged: privileged)
        let hasBattery = !options.simulateNoBattery && BatteryReader.isPresent
        dashboard = DashboardStore(file: directories.root.appending(path: "Dashboard.json"), hasBattery: hasBattery)
        mods = ModsModel(store: store, directories: directories, panel: panelState, dashboard: dashboard)
        processes = ProcessMonitor(panel: panelState)
        memoryOptimizer = MemoryOptimizer(helper: privileged, store: store, panel: panelState)
        loginItem = LoginItem(canChange: options.managesLoginItem)
        systemEvents = SystemEventMonitor(observing: { store.observedEvents }, post: { store.post($0) })
        notifier = ModNotifier(center: ModNotifier.center(for: options), mods: mods)
        settings = AppSettings(file: directories.root.appending(path: "Settings.json"))
        alerts = SystemAlerts(
            settings: settings, hasBattery: hasBattery,
            isReclaimingMemory: { [memoryOptimizer] in memoryOptimizer.isBusy },
            post: { [notifier] alert, title, body in
                Task { await notifier.show(title: title, body: body, topic: .alerts, id: alert.rawValue) }
            },
            isRefused: { [notifier] askingFirst in await notifier.isRefused(askingFirst: askingFirst) }
        )
        var fetchRelease: () async throws -> (Data, URLResponse) = { try await UpdateCheck.session.data(for: UpdateCheck.request()) }
        var installation = UpdateInstaller.Environment.running(
            isBusy: { [panelState, mods, memoryOptimizer] in
                panelState.dialog != nil || mods.isInstalling || mods.isChangingHelper || memoryOptimizer.isBusy
            },
            restart: { [options, panelState] bundle in
                try AppReplacement.relaunch(bundle, after: getpid(), arguments: options.relaunchArguments(openingPanel: panelState.isVisible))
                Self.quit()
            }
        )
        #if DEBUG
        if let feed = options.updateFeed {
            fetchRelease = DebugUpdateFeed.fetch(feed)
            installation.trustedKey = DebugUpdateFeed.key(feed)
            installation.download = DebugUpdateFeed.download(feed)
        }
        #endif
        updates = UpdateChecker(settings: settings, mayCheckAutomatically: options.checksForUpdates, fetch: fetchRelease) { [notifier] release in
            let notification = UpdateCheck.notification(for: release)
            Task { await notifier.show(title: notification.title, body: notification.body, topic: .update, id: release.version.description) }
        }
        installer = UpdateInstaller(environment: installation)
        super.init()
        notifier.openPanel = { [weak self] page in self?.openPanel(on: page) }
        mods.presentPanel = { [weak self] in self?.openPanel(on: nil) }
        panelState.addVisibilityHandler { [dashboard, updates] visible in
            guard !visible else { return }
            dashboard.isEditing = false  // closing the panel ends editing
            updates.dismissUpdated()  // the panel has said that Toolsy was updated
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let appearance = options.appearance {
            NSApp.appearance = NSAppearance(named: appearance)
        }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = Self.statusImage(dropTarget: false)
            button.toolTip = "Toolsy"
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
            let dropView = StatusItemDropView(frame: button.bounds)
            dropView.toolTip = button.toolTip
            dropView.onTargetChange = { [weak self] targeted in self?.showDropTarget(targeted) }
            dropView.onDrop = { [weak self] urls in self?.mods.install(urls) }
            button.addSubview(dropView)
        }
        statusItem = item
        panelState.addVisibilityHandler { [weak self] visible in
            self?.statusItem?.button?.highlight(visible)
        }
        handOffObserver = SingleInstance.observeHandOffs { [weak self] in
            self?.openPanel(on: nil)
        }
        handleTerminationSignals()
        // Loading mods reads their folders and restarts services; the menu bar icon does not wait for it.
        mods.start()
        systemEvents.start()
        alerts.start()
        updates.start()
        loginItem.registerOnFirstLaunch()
        if options.openAtLaunch {
            // The menu bar places the new status item asynchronously; open once it has a frame.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.openPanel(on: nil)
            }
        }
        #if DEBUG
        if let script = options.script {
            DebugScript.start(script, app: self)
        }
        #endif
    }

    /// Files opened with Toolsy: a double-clicked `.toolsymod` (also when that launches the app),
    /// or `open -a Toolsy <file>`.
    func application(_ application: NSApplication, open urls: [URL]) {
        mods.install(urls.filter(\.isFileURL))
    }

    // MARK: Quitting

    /// Mods' services are children of the app and must stop with it. The answer waits for them, but
    /// never more than a few seconds: a hung mod must not keep Toolsy from quitting.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminating else { return .terminateLater }
        isTerminating = true
        systemEvents.stop()
        alerts.stop()
        updates.stop()
        Task {
            await mods.shutdown(within: .seconds(4))
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Quits from code that runs as a block of the main dispatch queue (a signal handler, a task).
    /// `terminate` must not be called from such a block: the shutdown it waits for runs on the main
    /// queue, which cannot drain while one of its own blocks is still running, so quitting would hang.
    /// A run loop block is outside the queue.
    static func quit() {
        RunLoop.main.perform(inModes: [.default]) {
            MainActor.assumeIsolated { NSApp.terminate(nil) }
        }
    }

    /// `pkill -TERM` (the install script replacing a running copy) and Ctrl-C quit like the menu does.
    private func handleTerminationSignals() {
        for signalNumber in [SIGTERM, SIGINT] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler {
                MainActor.assumeIsolated { Self.quit() }
            }
            source.resume()
            signalSources.append(source)
        }
    }

    // MARK: Status item

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let wantsMenu = event?.type == .rightMouseDown || event?.modifierFlags.contains(.control) == true
        if wantsMenu {
            panelController?.hide()
            showMenu()
        } else if panelState.isPresented {
            panelController?.hide()
        } else {
            openPanel(on: nil, anchor: event?.window)
        }
    }

    private static func statusImage(dropTarget: Bool) -> NSImage? {
        let image = NSImage(systemSymbolName: dropTarget ? "square.and.arrow.down.fill" : "wrench.and.screwdriver",
                            accessibilityDescription: "Toolsy")
        image?.isTemplate = true
        return image
    }

    /// While a file is dragged over the menu bar icon, it turns into a highlighted "drop here" symbol.
    func showDropTarget(_ targeted: Bool) {
        guard let button = statusItem?.button else { return }
        button.image = Self.statusImage(dropTarget: targeted)
        button.highlight(targeted || panelState.isPresented)
    }

    /// Opens the panel, optionally on a given page. `anchor` is the status bar window that was
    /// clicked; with several displays it tells which menu bar the panel belongs under.
    func openPanel(on page: PanelPage?, anchor: NSWindow? = nil) {
        let controller = panelController ?? makePanelController()
        controller.show(page: page ?? pendingStartPage, anchor: anchor ?? statusItem?.button?.window)
        pendingStartPage = nil
    }

    private func makePanelController() -> PanelController {
        let controller = PanelController(state: panelState, options: options, mods: mods, loginItem: loginItem,
                                         dashboard: dashboard, processes: processes, memoryOptimizer: memoryOptimizer,
                                         alerts: alerts, updates: updates, installer: installer)
        panelController = controller
        return controller
    }

    // MARK: Menu

    private func showMenu() {
        guard let item = statusItem else { return }
        let menu = NSMenu()
        menu.addItem(withTitle: String(localized: "Open Toolsy"), action: #selector(openFromMenu), keyEquivalent: "")
            .image = NSImage(systemSymbolName: "wrench.and.screwdriver", accessibilityDescription: nil)
        menu.addItem(withTitle: String(localized: "Settings…"), action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Quit Toolsy"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for entry in menu.items where entry.action != #selector(NSApplication.terminate(_:)) {
            entry.target = self
        }
        // Assigning the menu for the duration of one click gives the native placement and
        // highlight; left clicks keep going to `statusItemClicked`.
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    @objc private func openFromMenu() {
        openPanel(on: .root)
    }

    @objc private func openSettings() {
        openPanel(on: .settings)
    }
}

/// Lies over the status item's button and accepts files dropped on the menu bar icon. The button
/// itself cannot be a drop target (it belongs to the system), so this view is, and hands every
/// mouse event on to the button so clicks, the highlight and the menu behave as before.
final class StatusItemDropView: NSView {
    var onTargetChange: (Bool) -> Void = { _ in }
    var onDrop: ([URL]) -> Void = { _ in }

    override init(frame: NSRect) {
        super.init(frame: frame)
        autoresizingMask = [.width, .height]
        registerForDraggedTypes([.fileURL])
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not used from a nib")
    }

    override func mouseDown(with event: NSEvent) { superview?.mouseDown(with: event) }
    override func mouseUp(with event: NSEvent) { superview?.mouseUp(with: event) }
    override func mouseDragged(with event: NSEvent) { superview?.mouseDragged(with: event) }
    override func rightMouseDown(with event: NSEvent) { superview?.rightMouseDown(with: event) }
    override func rightMouseUp(with event: NSEvent) { superview?.rightMouseUp(with: event) }
    override func otherMouseDown(with event: NSEvent) { superview?.otherMouseDown(with: event) }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let accepts = !Self.fileURLs(in: sender).isEmpty
        onTargetChange(accepts)
        return accepts ? .copy : []
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        onTargetChange(false)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let urls = Self.fileURLs(in: sender)
        onTargetChange(false)
        onDrop(urls)
        return !urls.isEmpty
    }

    private static func fileURLs(in info: any NSDraggingInfo) -> [URL] {
        let objects = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        return (objects as? [URL]) ?? []
    }
}
