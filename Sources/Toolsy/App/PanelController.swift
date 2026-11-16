import AppKit
import SwiftUI

/// The borderless, transparent panel under the status item. It never activates the app (like
/// Control Center), can still become key so text fields work, floats above full-screen apps on
/// every Space, and is dismissed by outside clicks, Esc or another app taking focus.
final class PanelController: NSObject, NSWindowDelegate {
    private let state: PanelState
    private let keepOpen: Bool
    let window = GlassPanel()
    private let monitor: SystemMonitor
    private var anchor: NSWindow?
    private var dismissalMonitors: [Any] = []
    private var activationObserver: NSObjectProtocol?
    /// Greater than zero while the panel presents its own modal window (an `NSOpenPanel`);
    /// focus moving there must not close the panel.
    private var modalDepth = 0
    private var contentHeight: CGFloat = 0
    private var pendingShrink: Task<Void, Never>?

    init(state: PanelState, options: LaunchOptions, mods: ModsModel, loginItem: LoginItem) {
        self.state = state
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
        let root = PanelRootView { [weak self] height in self?.contentHeightChanged(height) }
            .environment(state)
            .environment(monitor)
            .environment(mods)
            .environment(loginItem)
        let hosting = PanelHostingView(rootView: root)
        // The window size is driven by `contentHeightChanged`, not by the hosting view.
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
        pendingShrink?.cancel()
        self.anchor = anchor
        updateMaximumHeight()
        // Lay out once before the window appears so its first frame already has the right size.
        window.contentView?.layoutSubtreeIfNeeded()
        setWindowHeight(contentHeight)
        window.orderFrontRegardless()
        window.makeKey()
        installDismissalMonitors()
        state.setVisible(true)
        withAnimation(Motion.resolve(.spring(response: 0.3, dampingFraction: 0.82), reduceMotion: reduceMotion)) {
            state.isPresented = true
        }
        FileHandle.standardOutput.write(Data("Toolsy panel window \(window.windowNumber)\n".utf8))
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

    /// The status item's window, if it is placed in a menu bar. Right after launch, or when the
    /// item is hidden behind the notch, it is not, and the panel falls back to the top right.
    private var anchorFrame: NSRect? {
        guard let anchor, let screen = anchor.screen,
              anchor.frame.minY >= screen.visibleFrame.maxY - 1 else { return nil }
        return anchor.frame
    }

    private var screen: NSScreen? {
        anchorFrame != nil ? anchor?.screen : NSScreen.main
    }

    /// Top edge of the panel: just under the menu bar.
    private var panelTop: CGFloat {
        guard let screen else { return 0 }
        return min(anchorFrame?.minY ?? .infinity, screen.visibleFrame.maxY) - 2
    }

    private func updateMaximumHeight() {
        guard let screen else { return }
        let available = panelTop - screen.visibleFrame.minY - 2 * Metrics.panelInset
        state.maxHeight = max(200, available)
    }

    private func contentHeightChanged(_ height: CGFloat) {
        let grows = height >= contentHeight
        contentHeight = height
        pendingShrink?.cancel()
        guard window.isVisible else { return }
        if grows {
            setWindowHeight(height)
        } else {
            // SwiftUI animates the content to its smaller size; shrinking the window at once
            // would clip that animation, so wait for it to finish.
            pendingShrink = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(450)) } catch { return }
                self?.setWindowHeight(height)
            }
        }
    }

    private func setWindowHeight(_ contentHeight: CGFloat) {
        guard let screen else { return }
        let visible = screen.visibleFrame
        let width = Metrics.panelWidth + 2 * Metrics.panelInset
        let height = min(contentHeight, state.maxHeight) + 2 * Metrics.panelInset
        // Like a menu, the panel's leading edge lines up with the status item, and it is kept
        // on screen. The inset leaves room for the glass rim, so it may touch the screen edge.
        let anchorX = anchorFrame?.minX ?? visible.maxX
        let x = min(max(anchorX - Metrics.panelInset, visible.minX), visible.maxX - width)
        let frame = NSRect(x: x, y: panelTop - height, width: width, height: height)
        window.setFrame(frame, display: true)
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
            handler: { [weak self] _ in MainActor.assumeIsolated { self?.dismissIfIdle() } }
        ) {
            dismissalMonitors.append(monitor)
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let isOtherApp = app?.processIdentifier != ProcessInfo.processInfo.processIdentifier
            MainActor.assumeIsolated {
                if isOtherApp { self?.dismissIfIdle() }
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
    }

    /// Esc closes the dialog if one is shown, otherwise the panel. Returns whether it was handled.
    private func handleKeyDown(isEscape: Bool, windowNumber: Int) -> Bool {
        guard isEscape, windowNumber == window.windowNumber else { return false }
        if let dialog = state.dialog {
            // Work in progress (installing while macOS asks for the password) cannot be cancelled here.
            if !dialog.isProgress { state.dismissDialog(confirmed: false) }
        } else if !keepOpen {
            hide()
        }
        return true
    }

    private func dismissIfIdle() {
        guard modalDepth == 0, state.holdCount == 0, !keepOpen else { return }
        hide()
    }

    func windowDidResignKey(_ notification: Notification) {
        // Focus went to another app's window (Spotlight, a notification) rather than to one of
        // ours, e.g. the open panel.
        guard state.isPresented, modalDepth == 0, state.holdCount == 0, NSApp.keyWindow == nil else { return }
        dismissIfIdle()
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
