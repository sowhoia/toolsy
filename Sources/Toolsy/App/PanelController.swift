import AppKit
import SwiftUI

/// The borderless, transparent panel under the status item. It never activates the app (like
/// Control Center), can still become key so text fields work, floats above full-screen apps on
/// every Space, and is dismissed by outside clicks, Esc or another app taking focus. A press outside
/// that may start a drag to the panel closes it only once released elsewhere (`OutsideDismissal`).
final class PanelController: NSObject, NSWindowDelegate {
    private let state: PanelState
    private let keepOpen: Bool
    let window = GlassPanel()
    private let monitor: SystemMonitor
    private let dashboard: DashboardStore
    private var anchor: NSWindow?
    private var dismissalMonitors: [Any] = []
    private var activationObserver: NSObjectProtocol?
    private var outsideDismissal = OutsideDismissal()
    /// Greater than zero while the panel presents its own modal window (an `NSOpenPanel`);
    /// focus moving there must not close the panel.
    private var modalDepth = 0

    init(state: PanelState, options: LaunchOptions, mods: ModsModel, loginItem: LoginItem,
         dashboard: DashboardStore, processes: ProcessMonitor, memoryOptimizer: MemoryOptimizer) {
        self.state = state
        self.dashboard = dashboard
        keepOpen = options.keepOpen
        monitor = SystemMonitor(simulateNoBattery: options.simulateNoBattery)
        super.init()
        window.delegate = self
        state.chooseFilesHandler = { [weak self] openPanel in
            await self?.runModal(openPanel) ?? []
        }
        state.addVisibilityHandler { [monitor] visible in
            visible ? monitor.start() : monitor.stop()
        }
        // A display that was unplugged or rearranged invalidates where an open panel was placed.
        // The controller lives as long as the app, so the observer is never removed.
        _ = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.window.isVisible else { return }
                self.place()
            }
        }
        let root = PanelRootView()
            .environment(state)
            .environment(monitor)
            .environment(dashboard)
            .environment(mods)
            .environment(loginItem)
            .environment(processes)
            .environment(memoryOptimizer)
        let hosting = PanelHostingView(rootView: root)
        // The window keeps the frame of its placement; the content never resizes it.
        hosting.sizingOptions = []
        window.contentView = hosting
    }

    // MARK: Showing and hiding

    func show(page: PanelPage?, anchor: NSWindow?) {
        if let page { state.show(page) }
        if state.isPresented {
            window.makeKey()
            return
        }
        self.anchor = anchor
        place()
        window.orderFrontRegardless()
        window.makeKey()
        installDismissalMonitors()
        state.setVisible(true)
        withAnimation(Motion.resolve(.spring(response: 0.3, dampingFraction: 0.82), reduceMotion: reduceMotion)) {
            state.isPresented = true
        }
        #if DEBUG
        // For captures of a scripted run by window number.
        FileHandle.standardOutput.write(Data("Toolsy panel window \(window.windowNumber)\n".utf8))
        #endif
    }

    func hide() {
        guard state.isPresented else { return }
        removeDismissalMonitors()
        if state.dialog != nil { state.dismissDialog(confirmed: false) }
        withAnimation(.easeIn(duration: reduceMotion ? 0.12 : 0.16)) {
            state.isPresented = false
        } completion: { [weak self] in
            // A click may have reopened the panel while it was fading out.
            guard let self, !self.state.isPresented else { return }
            self.window.orderOut(nil)
            self.state.show(.root)
            self.state.setVisible(false)
        }
    }

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    // MARK: Geometry

    /// Puts the window where this presentation of the panel belongs. Called when the panel opens (and
    /// when the displays change under it), never because its content changed; see `PanelPlacement`.
    private func place() {
        // The status item's own screen when the item sits in a menu bar, else the screen in use.
        let item = anchor.flatMap { item in
            item.screen.flatMap { PanelPlacement.isInMenuBar(item.frame, of: $0.frame) ? (frame: item.frame, screen: $0) : nil }
        }
        guard let screen = item?.screen ?? NSScreen.main else { return }
        let placement = PanelPlacement(anchor: item?.frame, visibleFrame: screen.visibleFrame)
        state.maxHeight = placement.maxContentHeight
        window.setFrame(placement.frame, display: true)
    }

    // MARK: Dismissal

    private func installDismissalMonitors() {
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            // Local monitors run on the main thread; only the Sendable facts cross over.
            let isEscape = event.keyCode == 53
            let windowNumber = event.windowNumber
            let handled = MainActor.assumeIsolated { self?.handleKeyDown(isEscape: isEscape, windowNumber: windowNumber) ?? false }
            return handled ? nil : event
        }) {
            dismissalMonitors.append(monitor)
        }
        guard !keepOpen else { return }
        if let monitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown],
            handler: { [weak self] event in
                let outside: OutsideDismissal.Event = event.type == .leftMouseDown ? .leftClickOrFocusChange : .otherButtonDown
                MainActor.assumeIsolated { self?.somethingHappenedOutside(outside) }
            }
        ) {
            dismissalMonitors.append(monitor)
        }
        // The release goes to the app that had the press: another one (a drag from Finder), or this one.
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.leftButtonReleased() }
        }) {
            dismissalMonitors.append(monitor)
        }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.leftButtonReleased() }
            return event
        }) {
            dismissalMonitors.append(monitor)
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let isOtherApp = app?.processIdentifier != ProcessInfo.processInfo.processIdentifier
            MainActor.assumeIsolated {
                if isOtherApp { self?.somethingHappenedOutside(.leftClickOrFocusChange) }
            }
        }
    }

    private func removeDismissalMonitors() {
        dismissalMonitors.forEach(NSEvent.removeMonitor)
        dismissalMonitors.removeAll()
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        activationObserver = nil
        outsideDismissal = OutsideDismissal()
    }

    /// Esc closes the dialog if one is shown, then leaves editing the dashboard, otherwise closes the
    /// panel; while an input method composes text in a field, it is the field's. Returns whether it was
    /// handled.
    private func handleKeyDown(isEscape: Bool, windowNumber: Int) -> Bool {
        guard isEscape, windowNumber == window.windowNumber else { return false }
        // A field being edited has the window's field editor, a text view, as its first responder.
        let composing = (window.firstResponder as? NSTextView)?.hasMarkedText() == true
        switch EscapeAction(composingText: composing, dialog: state.dialog, isEditing: dashboard.isEditing, keepOpen: keepOpen) {
        case .passOn:
            return false
        case .ignore:
            break
        case .cancelDialog:
            state.dismissDialog(confirmed: false)
        case .stopEditing:
            withAnimation(Motion.resolve(Motion.gentle, reduceMotion: reduceMotion)) { dashboard.isEditing = false }
        case .closePanel:
            hide()
        }
        return true
    }

    /// Whether something outside may close the panel: not while the panel's own open panel or a system prompt
    /// it waits for has the focus, and never with `--keep-open`.
    private var isIdle: Bool {
        modalDepth == 0 && state.holdCount == 0 && !keepOpen
    }

    private func somethingHappenedOutside(_ event: OutsideDismissal.Event) {
        guard isIdle else { return }
        if outsideDismissal.handle(event, leftButtonHeld: NSEvent.pressedMouseButtons & 1 != 0) { hide() }
    }

    private func leftButtonReleased() {
        guard outsideDismissal.isWaitingForRelease else { return }
        let closes = outsideDismissal.leftButtonReleased(at: NSEvent.mouseLocation, frame: glassFrameOnScreen)
        guard isIdle, state.isPresented else { return }
        if closes {
            hide()
        } else {
            // Released over the panel, such as a mod's file dropped on it: the panel takes back the keyboard
            // focus the press may have taken, for what follows (Return confirms the installation).
            window.makeKey()
        }
    }

    /// Where the panel's glass is on screen. The rest of the window is clear and lets clicks through.
    private var glassFrameOnScreen: CGRect {
        guard let content = window.contentView else { return .zero }
        return window.convertToScreen(content.convert(state.glassFrame, to: nil))
    }

    func windowDidResignKey(_ notification: Notification) {
        // Focus went to another app's window (Spotlight, a notification) rather than to one of
        // ours, e.g. the open panel.
        guard state.isPresented, NSApp.keyWindow == nil else { return }
        somethingHappenedOutside(.leftClickOrFocusChange)
    }

    // MARK: Modal windows

    /// Runs an open panel above the panel without dismissing it and returns the chosen URLs.
    private func runModal(_ openPanel: NSOpenPanel) async -> [URL] {
        modalDepth += 1
        defer {
            modalDepth -= 1
            window.makeKey()
        }
        openPanel.level = NSWindow.Level(rawValue: window.level.rawValue + 1)
        NSApp.activate()
        let response = await withCheckedContinuation { continuation in
            openPanel.begin { continuation.resume(returning: $0) }
        }
        return response == .OK ? openPanel.urls : []
    }
}

/// Like a menu, the panel acts on the first click even while another window has focus (after the
/// password prompt, or a click into another app with the panel pinned). Without this, controls
/// outside a scroll view, such as the switch in a page header, only take focus on the first click.
final class PanelHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The window behind the panel. All drawing is SwiftUI's; the window itself is clear.
final class GlassPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Metrics.panelWidth, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        isOpaque = false
        backgroundColor = .clear
        // The glass draws its own edge and shadow; a window shadow would outline the
        // transparent gaps between tiles.
        hasShadow = false
        isFloatingPanel = true
        // After `isFloatingPanel`, which resets the level to `.floating`.
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovable = false
        animationBehavior = .none
    }

    #if DEBUG
    /// Set for scripted runs on the owner's desktop: the panel must not take their keystrokes.
    static var refusesKey = false
    override var canBecomeKey: Bool { !Self.refusesKey }
    #else
    override var canBecomeKey: Bool { true }
    #endif
    override var canBecomeMain: Bool { false }
}
