import AppKit

/// When something outside the panel closes it, decided apart from the events so it can be tested.
///
/// A press of the left button outside the panel usually means the user went on with something else, but it
/// may also start a drag to the panel: a mod's file from Finder. So while the left button is held, closing
/// waits for its release, and then happens only if the pointer is not over the panel. The right and other
/// buttons start no such drag and close the panel at once.
struct OutsideDismissal {
    enum Event: Equatable {
        /// The left button went down in another app, another app became active, or a window of another app
        /// took the keyboard focus: any of them happens when a drag starts in Finder.
        case leftClickOrFocusChange
        /// The right or another button went down in another app.
        case otherButtonDown
    }

    /// An event outside waits for the left button's release to decide.
    private(set) var isWaitingForRelease = false

    /// Something happened outside the panel while the left button was held or not. Returns whether the
    /// panel closes now.
    mutating func handle(_ event: Event, leftButtonHeld: Bool) -> Bool {
        switch event {
        case .otherButtonDown:
            isWaitingForRelease = false
            return true
        case .leftClickOrFocusChange:
            // Once waiting, the release decides: focus moving on during the drag, or just after the drop
            // (in whatever order the system reports it), is the same drag.
            if isWaitingForRelease { return false }
            isWaitingForRelease = leftButtonHeld
            return !leftButtonHeld
        }
    }

    /// The left button was released with the pointer at `pointer`. Returns whether the panel closes: only
    /// when an event outside was waiting for the release and the pointer is not over the panel's `frame`.
    mutating func leftButtonReleased(at pointer: CGPoint, frame: CGRect) -> Bool {
        defer { isWaitingForRelease = false }
        return isWaitingForRelease && !frame.contains(pointer)
    }
}

/// What Esc does in the panel.
enum EscapeAction: Equatable {
    /// Esc is not the panel's: an input method is composing text in the focused field, and Esc cancels the
    /// composition.
    case passOn
    /// Esc is the panel's but does nothing: a notice of work in progress cannot be cancelled, and a panel
    /// kept open (`--keep-open`) does not close.
    case ignore
    case cancelDialog
    case stopEditing
    case closePanel

    init(composingText: Bool, dialog: ConfirmationRequest?, isEditing: Bool, keepOpen: Bool) {
        if composingText {
            self = .passOn
        } else if let dialog {
            self = dialog.isProgress ? .ignore : .cancelDialog
        } else if isEditing {
            self = .stopEditing
        } else {
            self = keepOpen ? .ignore : .closePanel
        }
    }
}

/// The moments after which nobody can be looking at the panel: the displays went to sleep (a locked screen
/// too, once its displays sleep), the Mac is going to sleep, or the session was switched to another user. A
/// panel left open would otherwise keep the Mac's readings and the mods' refresh commands running all night.
enum Absence {
    static let notifications = [NSWorkspace.screensDidSleepNotification, NSWorkspace.willSleepNotification,
                                NSWorkspace.sessionDidResignActiveNotification]

    /// Calls `handler` on each of them, posted to `center` (the workspace's). The observers are never removed:
    /// the panel controller lives as long as the app.
    static func observe(in center: NotificationCenter = NSWorkspace.shared.notificationCenter,
                        _ handler: @escaping @MainActor () -> Void) {
        for name in notifications {
            _ = center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { handler() }
            }
        }
    }
}
