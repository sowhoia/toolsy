#if DEBUG
import AppKit
import ToolsyEngine
import ToolsyShared

/// Drives a debug run from a script file (`--script`), so behaviour and screenshots can be checked
/// without touching the owner's mouse and keyboard: clicks, drags and keys are `NSEvent`s sent to
/// the panel window inside this process, everything else calls the app's model directly. One
/// command per line, `#` starts a comment:
///
///     wait <seconds>                 open [page]          close          page <page>|back
///     appearance light|dark          install <path>…      answer confirm|cancel
///     waitdialog                     dialog               click <anchor>
///     clickat <anchor> <x> <y>       drag <anchor> <from> <to>
///     press <anchor> <x> <y>         moveto <anchor> <x> <y>             release
///     type <text>                    key return|tab|escape               blur
///     allowkey                       reveal <anchor>      scroll <points>
///     waitfor <mod> <expression>     assert <mod> <expression>
///     set <mod> <key> <json> [command]                    run <mod> <command>
///     state <mod>     running <mod>  history <mod> <key>  access <mod>
///     helper cancel-next|needs-update (the next password prompt is dismissed; Toolsy "was updated")
///     sh <shell command>
///     dropstatus on|off              droppanel on|off     capturedir <folder>
///     capture <name> [anchor]        print <text>         quit
///
/// Pages are root, settings, gallery and mod:<id>. Anchors are the names given with `debugAnchor`
/// (`tile:<id>`, `dialog-confirm`, …); a mod's control is `<id>/<index path>` or found by a field,
/// `<id>:bind=<key>`, `<id>:command=<name>`, `<id>:label=<text>`. `clickat` takes fractions of the
/// anchor's width and height from its top left; `drag` positions are fractions of its width along
/// its bottom edge (where a slider's track is). `press` holds the mouse button down at a point given
/// like `clickat`'s and `moveto` drags it elsewhere, so a pressed or dragged control can be captured;
/// `release` lets go. `capture` with an anchor captures only that control. `set` and `run` go through
/// the same model calls as the controls (for the menu picker, whose native menu would block the script).
@MainActor
enum DebugScript {
    static func start(_ file: URL, app: AppDelegate) {
        // Measurements turn the anchors off: recording them observes the geometry of every control.
        DebugAnchors.isRecording = ProcessInfo.processInfo.environment["TOOLSY_NO_ANCHORS"] == nil
        GlassPanel.refusesKey = true
        let text: String
        do {
            text = try String(contentsOf: file, encoding: .utf8)
        } catch {
            FileHandle.standardError.write(Data("SCRIPT cannot read \(file.path): \(error.localizedDescription)\n".utf8))
            NSApp.terminate(nil)
            return
        }
        Task { await Runner(app: app).run(text) }
    }
}

@MainActor
private final class Runner {
    let app: AppDelegate
    var failures = 0
    var captureFolder = URL(filePath: FileManager.default.currentDirectoryPath)
    var backdrop: NSWindow?

    init(app: AppDelegate) {
        self.app = app
    }

    var mods: ModsModel { app.mods }
    var panel: PanelState { app.panelState }
    var window: NSWindow? { app.panelController?.window }

    func run(_ text: String) async {
        await mods.waitUntilStarted()
        for (number, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let words = line.split(separator: " ", maxSplits: 1).map(String.init)
            let rest = words.count > 1 ? words[1] : ""
            do {
                try await execute(words[0], rest)
            } catch {
                fail("line \(number + 1) “\(line)”: \(error.localizedDescription)")
            }
        }
        say("DONE failures=\(failures)")
    }

    // MARK: Commands

    func execute(_ command: String, _ rest: String) async throws {
        let arguments = rest.split(separator: " ").map(String.init)
        switch command {
        case "wait":
            try await Task.sleep(for: .seconds(Double(rest) ?? 0.5))
        case "open":
            app.openPanel(on: rest.isEmpty ? nil : try page(rest))
            try await Task.sleep(for: .seconds(0.6))
        case "close":
            app.panelController?.hide()
            try await Task.sleep(for: .seconds(0.4))
        case "page":
            if rest == "back" { panel.pop() } else { panel.push(try page(rest)) }
            try await Task.sleep(for: .seconds(0.6))
        case "appearance":
            NSApp.appearance = NSAppearance(named: rest == "dark" ? .darkAqua : .aqua)
            try await Task.sleep(for: .seconds(0.4))
        case "install":
            mods.install(arguments.map { URL(filePath: $0).standardizedFileURL })
        case "waitdialog":
            try await waitFor("a dialog") { self.panel.dialog != nil }
            try await Task.sleep(for: .seconds(0.4))
            printDialog()
        case "dialog":
            printDialog()
        case "answer":
            guard panel.dialog != nil else { throw ScriptError("no dialog to answer") }
            panel.dismissDialog(confirmed: rest == "confirm")
            try await Task.sleep(for: .seconds(0.3))
        case "click":
            try await click(at: center(of: rest))
        case "clickat":
            guard arguments.count == 3, let fx = Double(arguments[1]), let fy = Double(arguments[2]) else {
                throw ScriptError("clickat <anchor> <x> <y>")
            }
            let rect = try frame(of: arguments[0])
            try await click(at: NSPoint(x: rect.minX + rect.width * fx, y: rect.maxY - rect.height * fy))
        case "blur":
            window?.makeFirstResponder(nil)
            try await Task.sleep(for: .milliseconds(300))
        case "set":
            let parts = rest.split(separator: " ", maxSplits: 2).map(String.init)
            guard parts.count == 3, let mod = mods.mod(id: parts[0]) else { throw ScriptError("set <mod> <key> <json> [command]") }
            // The JSON value may itself contain spaces; a trailing word that is a command of the mod is the command.
            var json = parts[2]
            var command: String?
            if let space = json.lastIndex(of: " "), mod.manifest.commands[String(json[json.index(after: space)...])] != nil {
                command = String(json[json.index(after: space)...])
                json = String(json[..<space])
            }
            let value = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
            mods.setValue(value, for: parts[1], command: command, of: mod)
            try await Task.sleep(for: .milliseconds(300))
        case "run":
            let (mod, name) = try modAndRest(rest)
            mods.run(name, of: mod)
            try await Task.sleep(for: .milliseconds(200))
        case "running":
            let (mod, _) = try modAndRest(rest)
            say("RUNNING \(mod.id) \(mod.runningCommands.sorted()) switching=\(mod.isSwitching)")
        case "history":
            let (mod, key) = try modAndRest(rest)
            let samples = mod.history(of: key)
            say("HISTORY \(mod.id) \(key) count=\(samples.count) last=\(samples.suffix(3))")
        case "sh":
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(filePath: "/bin/sh")
            process.arguments = ["-c", rest]
            process.standardOutput = output
            process.standardError = output
            try process.run()
            let data = try await Task.detached { try output.fileHandleForReading.readToEnd() ?? Data() }.value
            process.waitUntilExit()
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n") { say("SH \(line)") }
        case "drag":
            guard arguments.count == 3, let from = Double(arguments[1]), let to = Double(arguments[2]) else {
                throw ScriptError("drag <anchor> <from> <to>")
            }
            try await drag(arguments[0], from: from, to: to)
        case "press", "moveto":
            guard arguments.count == 3, let fx = Double(arguments[1]), let fy = Double(arguments[2]) else {
                throw ScriptError("\(command) <anchor> <x> <y>")
            }
            let rect = try frame(of: arguments[0])
            let target = NSPoint(x: rect.minX + rect.width * fx, y: rect.maxY - rect.height * fy)
            if command == "press" {
                send(.leftMouseDown, at: target)
                heldAt = target
            }
            guard let start = heldAt else { throw ScriptError("moveto needs press first") }
            // A few drag events on the way, so a gesture sees movement (and a speed) like a real drag.
            for step in 1...6 {
                try await Task.sleep(for: .milliseconds(30))
                let t = CGFloat(step) / 6
                send(.leftMouseDragged, at: NSPoint(x: start.x + (target.x - start.x) * t, y: start.y + (target.y - start.y) * t))
            }
            heldAt = target
            try await Task.sleep(for: .milliseconds(250))
        case "release":
            guard let point = heldAt else { throw ScriptError("release needs press first") }
            send(.leftMouseUp, at: point)
            heldAt = nil
            try await Task.sleep(for: .milliseconds(300))
        case "type":
            for character in rest {
                key(String(character), code: 0)
                try await Task.sleep(for: .milliseconds(30))
            }
        case "key":
            switch rest {
            case "return": key("\r", code: 36)
            case "tab": key("\t", code: 48)
            case "escape": key("\u{1b}", code: 53)
            default: throw ScriptError("unknown key \(rest)")
            }
            try await Task.sleep(for: .milliseconds(200))
        case "hittest":
            let point = try center(of: rest)
            var view = window?.contentView?.hitTest(window?.contentView?.superview?.convert(point, from: nil) ?? point)
            var chain: [String] = []
            while let current = view { chain.append("\(type(of: current))\(current.frame.integral)"); view = current.superview }
            say("HIT \(rest) at \(point): \(chain.joined(separator: " < "))")
        case "focus":
            // Clicks into a text field until its field editor has focus (the first click may only make the panel key).
            for _ in 0..<4 {
                if window?.firstResponder is NSTextView { return say("FOCUSED \(rest)") }
                viaQueue = true
                defer { viaQueue = false }
                let rect = try frame(of: rest)
                try await click(at: NSPoint(x: rect.minX + rect.width * 0.75, y: rect.midY))
                try await Task.sleep(for: .milliseconds(300))
            }
            throw ScriptError("\(rest) did not take focus")
        case "clickstatus":
            // A click on the menu bar icon, delivered to its window like the system would.
            guard let statusWindow = app.statusItemWindow, let content = statusWindow.contentView else { throw ScriptError("no status item") }
            let point = NSPoint(x: content.bounds.midX, y: content.bounds.midY)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: statusWindow.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                                  pressure: type == .leftMouseDown ? 1 : 0) {
                    NSApp.postEvent(event, atStart: false)
                }
            }
            try await Task.sleep(for: .milliseconds(800))
            say("PANEL presented=\(panel.isPresented)")
        case "queue":
            viaQueue = rest == "on"
        case "allowkey":
            GlassPanel.refusesKey = false
        case "makekey":
            window?.makeKey()
            try await Task.sleep(for: .milliseconds(200))
        case "reveal":
            try await reveal(rest)
        case "scroll":
            scroll(by: CGFloat(Double(rest) ?? 0))
            try await Task.sleep(for: .seconds(0.5))
        case "waitfor":
            let (mod, expression) = try modAndRest(rest)
            try await waitFor(expression, timeout: 15) { mod.evaluate(expression) }
            say("OK \(mod.id): \(expression)")
        case "assert":
            let (mod, expression) = try modAndRest(rest)
            if mod.evaluate(expression) { say("OK \(mod.id): \(expression)") } else { fail("\(mod.id): \(expression) is false") }
        case "state":
            let (mod, _) = try modAndRest(rest)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            say("STATE \(mod.id) \(String(decoding: try encoder.encode(mod.state), as: UTF8.self))")
        case "access":
            let (mod, _) = try modAndRest(rest)
            say("ACCESS \(mod.id) \(mod.access) helper=\(mods.store.helperStatus)")
        case "helper":
            guard let helper = app.simulatedHelper else { throw ScriptError("helper needs the simulated helper") }
            switch rest {
            case "cancel-next": await helper.failNextInstall(with: .cancelled)
            case "needs-update": await helper.simulateAppUpdate()
            default: throw ScriptError("helper cancel-next|needs-update")
            }
        case "dropstatus":
            app.showDropTarget(rest == "on")
        case "droppanel":
            panel.isDropTargeted = rest == "on"
            try await Task.sleep(for: .seconds(0.3))
        case "capturedir":
            captureFolder = URL(filePath: rest, directoryHint: .isDirectory).standardizedFileURL
            try FileManager.default.createDirectory(at: captureFolder, withIntermediateDirectories: true)
        case "capture":
            // `capture <name> [anchor]`: the whole panel, or only the anchor and a margin around it.
            try await capture(arguments.first ?? rest, anchor: arguments.count > 1 ? arguments[1] : nil)
        case "capturestatus":
            try await captureStatusItem(rest)
        case "anchors":
            say("ANCHORS " + DebugAnchors.entries.keys.sorted().filter { rest.isEmpty || $0.hasPrefix(rest) }
                .map { "\($0)=\(DebugAnchors.frame($0).map { "\($0.integral)" } ?? "")" }.joined(separator: " "))
        case "switch":
            let (mod, position) = try modAndRest(rest)
            mods.setEnabled(mod, position == "on")
            try await Task.sleep(for: .milliseconds(300))
        case "print":
            say(rest)
        case "quit":
            AppDelegate.quit()
        default:
            throw ScriptError("unknown command \(command)")
        }
    }

    func page(_ name: String) throws -> PanelPage {
        switch name {
        case "root": return .root
        case "settings": return .settings
        case "gallery": return .gallery
        case let mod where mod.hasPrefix("mod:"): return .mod(String(mod.dropFirst(4)))
        default: throw ScriptError("unknown page \(name)")
        }
    }

    func modAndRest(_ rest: String) throws -> (Mod, String) {
        let parts = rest.split(separator: " ", maxSplits: 1).map(String.init)
        guard let id = parts.first, let mod = mods.mod(id: id) else { throw ScriptError("no mod \(rest)") }
        return (mod, parts.count > 1 ? parts[1] : "")
    }

    func waitFor(_ what: String, timeout: Double = 10, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(timeout)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw ScriptError("timed out waiting for \(what)") }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    func printDialog() {
        guard let dialog = panel.dialog else { return say("DIALOG none") }
        say("DIALOG \(dialog.title) | \(dialog.message ?? "") | warning: \(dialog.warning ?? "-") | \(dialog.details.joined(separator: "; ")) | [\(dialog.confirmTitle)]")
    }

    // MARK: Events

    /// The anchor's frame in window coordinates.
    func frame(of name: String) throws -> NSRect {
        let resolved = try resolve(name)
        guard let rect = DebugAnchors.frame(resolved), let content = window?.contentView else {
            throw ScriptError("no anchor \(resolved) on screen")
        }
        return content.convert(rect, to: nil)
    }

    func center(of name: String) throws -> NSPoint {
        let rect = try frame(of: name)
        return NSPoint(x: rect.midX, y: rect.midY)
    }

    /// `<id>:<field>=<value>` finds the first control of the mod with that field.
    func resolve(_ name: String) throws -> String {
        guard let colon = name.firstIndex(of: ":"), let equals = name.firstIndex(of: "="), colon < equals,
              let mod = mods.mod(id: String(name[..<colon])) else { return name }
        let field = String(name[name.index(after: colon)..<equals])
        let value = String(name[name.index(after: equals)...])
        func search(_ controls: [ModControl], _ path: [Int]) -> [Int]? {
            for (index, control) in controls.enumerated() {
                if Self.field(field, of: control) == value { return path + [index] }
                switch control.kind {
                case .section(let section): if let found = search(section.children, path + [index]) { return found }
                case .row(let row): if let found = search(row.children, path + [index]) { return found }
                default: break
                }
            }
            return nil
        }
        guard let path = search(mod.manifest.ui, []) else { throw ScriptError("\(mod.id) has no control with \(field)=\(value)") }
        return "\(mod.id)/\(path.map(String.init).joined(separator: "."))"
    }

    static func field(_ field: String, of control: ModControl) -> String? {
        switch (field, control.kind) {
        case ("bind", .toggle(let c)): c.bind
        case ("bind", .slider(let c)): c.bind
        case ("bind", .stepper(let c)): c.bind
        case ("bind", .picker(let c)): c.bind
        case ("bind", .input(let c)): c.bind
        case ("bind", .list(let c)): c.bind
        case ("bind", .gauge(let c)): c.bind
        case ("command", .button(let c)): c.command
        case ("label", .button(let c)): c.label
        case ("label", .value(let c)): c.label
        case ("type", _): String(describing: control.kind).split(separator: "(").first.map(String.init)
        default: nil
        }
    }

    /// Through the app's own event queue when `viaQueue` (as the system delivers events), otherwise
    /// straight to the window.
    var viaQueue = false
    /// Where the mouse button is held down between `press` and `release`.
    var heldAt: NSPoint?

    func send(_ type: NSEvent.EventType, at point: NSPoint) {
        guard let window, let event = NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
            pressure: type == .leftMouseUp ? 0 : 1
        ) else { return }
        if viaQueue { NSApp.postEvent(event, atStart: false) } else { window.sendEvent(event) }
    }

    /// A click as a mouse delivers it: down, a drag event that does not move, up. SwiftUI's drag
    /// gestures (the switch) begin only with a drag event.
    func click(at point: NSPoint) async throws {
        send(.leftMouseDown, at: point)
        try await Task.sleep(for: .milliseconds(40))
        send(.leftMouseDragged, at: point)
        try await Task.sleep(for: .milliseconds(40))
        send(.leftMouseUp, at: point)
        try await Task.sleep(for: .milliseconds(350))
    }

    func drag(_ name: String, from: Double, to: Double) async throws {
        let rect = try frame(of: name)
        // A slider's track runs along the bottom of its row, inset by half its thumb.
        let y = rect.minY + 14
        func x(_ fraction: Double) -> CGFloat { rect.minX + 13 + (rect.width - 26) * fraction }
        send(.leftMouseDown, at: NSPoint(x: x(from), y: y))
        for step in 1...12 {
            try await Task.sleep(for: .milliseconds(40))
            send(.leftMouseDragged, at: NSPoint(x: x(from + (to - from) * Double(step) / 12), y: y))
        }
        try await Task.sleep(for: .milliseconds(80))
        send(.leftMouseUp, at: NSPoint(x: x(to), y: y))
        try await Task.sleep(for: .milliseconds(300))
    }

    func key(_ characters: String, code: UInt16) {
        guard let window else { return }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code
            ) {
                window.sendEvent(event)
            }
        }
    }

    /// Scrolls the page by `points` (positive: further down the page) by moving the clip view of the
    /// page's scroll view, as a scroll wheel would. (A synthesised wheel event does not reach it.)
    func scroll(by points: CGFloat) {
        func scrollView(in view: NSView) -> NSScrollView? {
            if let found = view as? NSScrollView { return found }
            return view.subviews.lazy.compactMap(scrollView(in:)).first
        }
        guard let content = window?.contentView, let scrollView = scrollView(in: content),
              let document = scrollView.documentView else { return }
        let clip = scrollView.contentView
        let limit = max(0, document.frame.height - clip.bounds.height)
        var origin = clip.bounds.origin
        origin.y = min(max(origin.y + (document.isFlipped ? points : -points), 0), limit)
        clip.scroll(to: origin)
        scrollView.reflectScrolledClipView(clip)
    }

    /// Scrolls until the anchor is inside the scrolling area, roughly centred.
    func reveal(_ name: String) async throws {
        for _ in 0..<8 {
            let target = try frame(of: name)
            let area = try frame(of: "scroll")
            if target.minY >= area.minY - 1, target.maxY <= area.maxY + 1 { return }
            // Window coordinates grow upwards; content further down the page has a smaller y.
            scroll(by: area.midY - target.midY)
            try await Task.sleep(for: .milliseconds(350))
        }
        throw ScriptError("could not scroll \(name) into view")
    }

    // MARK: Captures

    /// Captures the panel's region of the screen (a region capture shows the glass; a window capture
    /// does not), over a backdrop the size of the panel so nothing of the owner's screen is in it.
    func capture(_ name: String, anchor: String? = nil) async throws {
        guard let window else { throw ScriptError("the panel is not open") }
        showBackdrop(behind: window)
        try await Task.sleep(for: .seconds(0.7))
        let region = try anchor.map { window.convertToScreen(try frame(of: $0)).insetBy(dx: -12, dy: -12) } ?? window.frame
        try await screencapture(region.intersection(window.frame), to: name)
    }

    /// Only the menu bar icon itself, none of its neighbours.
    func captureStatusItem(_ name: String) async throws {
        guard let frame = app.statusItemFrame else { throw ScriptError("no status item") }
        try await Task.sleep(for: .seconds(0.4))
        try await screencapture(frame, to: name)
    }

    func screencapture(_ frame: NSRect, to name: String) async throws {
        let screenHeight = NSScreen.screens.first?.frame.height ?? 0
        let region = "\(Int(frame.minX)),\(Int(screenHeight - frame.maxY)),\(Int(frame.width)),\(Int(frame.height))"
        let file = captureFolder.appending(path: "\(name).png")
        let process = Process()
        process.executableURL = URL(filePath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-R", region, file.path(percentEncoded: false)]
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            process.terminationHandler = { _ in continuation.resume() }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
        guard process.terminationStatus == 0 else { throw ScriptError("screencapture failed (\(process.terminationStatus))") }
        say("CAPTURE \(file.path(percentEncoded: false))")
    }

    func showBackdrop(behind panelWindow: NSWindow) {
        let backdrop = self.backdrop ?? {
            let made = NSWindow(contentRect: panelWindow.frame, styleMask: .borderless, backing: .buffered, defer: false)
            made.isReleasedWhenClosed = false
            made.ignoresMouseEvents = true
            made.hasShadow = false
            made.level = NSWindow.Level(rawValue: panelWindow.level.rawValue - 1)
            made.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]
            made.contentView = BackdropView()
            self.backdrop = made
            return made
        }()
        backdrop.setFrame(panelWindow.frame, display: true)
        backdrop.contentView?.needsDisplay = true
        backdrop.orderFront(nil)
    }

    // MARK: Output

    func say(_ message: String) {
        FileHandle.standardOutput.write(Data("SCRIPT \(message)\n".utf8))
    }

    func fail(_ message: String) {
        failures += 1
        say("FAIL \(message)")
    }
}

/// A desktop-like gradient with soft colour, so the glass in captures has something to refract.
private final class BackdropView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let colors: [NSColor] = dark
            ? [NSColor(srgbRed: 0.10, green: 0.12, blue: 0.22, alpha: 1), NSColor(srgbRed: 0.22, green: 0.10, blue: 0.26, alpha: 1),
               NSColor(srgbRed: 0.05, green: 0.20, blue: 0.24, alpha: 1)]
            : [NSColor(srgbRed: 0.66, green: 0.78, blue: 0.95, alpha: 1), NSColor(srgbRed: 0.93, green: 0.76, blue: 0.86, alpha: 1),
               NSColor(srgbRed: 0.72, green: 0.90, blue: 0.84, alpha: 1)]
        NSGradient(colors: colors)?.draw(in: bounds, angle: -60)
        for (index, color) in [NSColor.systemOrange, .systemTeal, .systemPurple].enumerated() {
            let size = bounds.width * 0.7
            let center = NSPoint(x: bounds.width * [0.15, 0.9, 0.3][index], y: bounds.height * [0.8, 0.45, 0.1][index])
            let blob = NSRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size)
            NSGradient(colors: [color.withAlphaComponent(dark ? 0.35 : 0.45), color.withAlphaComponent(0)])?
                .draw(in: NSBezierPath(ovalIn: blob), relativeCenterPosition: .zero)
        }
    }
}

private struct ScriptError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
#endif
