import AppKit
import Testing
@testable import Toolsy

/// The panel's glass on a 1470 × 956 pt display, under a status item, and points over it and beside it.
private let glass = NSRect(x: 869, y: 520, width: 352, height: 400)
private let overThePanel = NSPoint(x: 1000, y: 700)
/// In the clear part of the window under the panel, or anywhere else: not the panel.
private let besideThePanel = NSPoint(x: 1000, y: 300)

/// Feeds events to an `OutsideDismissal` and records whether each closed the panel.
private struct Outside {
    private var dismissal = OutsideDismissal()
    var isWaiting: Bool { dismissal.isWaitingForRelease }

    mutating func click(heldWhenReported held: Bool) -> Bool {
        dismissal.handle(.leftClickOrFocusChange, leftButtonHeld: held)
    }

    mutating func otherButton(leftButtonHeld held: Bool = false) -> Bool {
        dismissal.handle(.otherButtonDown, leftButtonHeld: held)
    }

    mutating func release(at point: NSPoint) -> Bool {
        dismissal.leftButtonReleased(at: point, frame: glass)
    }
}

struct OutsideDismissalTests {
    @Test func aClickElsewhereClosesThePanel() {
        var outside = Outside()
        // Reported after the button came up again: at once.
        let reportedLate = outside.click(heldWhenReported: false)
        #expect(reportedLate)
        // Reported while it is still down: when it comes up, away from the panel.
        let reportedEarly = outside.click(heldWhenReported: true)
        #expect(!reportedEarly && outside.isWaiting)
        let released = outside.release(at: besideThePanel)
        #expect(released && !outside.isWaiting)
    }

    /// A mod's file dragged from Finder: the press there, then Finder's window taking the focus, then the
    /// drop on the panel.
    @Test func aDragFromAnotherAppDroppedOnThePanelKeepsItOpen() {
        var outside = Outside()
        let press = outside.click(heldWhenReported: true)
        let focus = outside.click(heldWhenReported: true)
        // Focus moving on as the drag ends may be reported before the release is.
        let lateFocus = outside.click(heldWhenReported: false)
        let drop = outside.release(at: overThePanel)
        #expect(![press, focus, lateFocus, drop].contains(true))
        #expect(!outside.isWaiting)
        // The next click elsewhere closes it again.
        let next = outside.click(heldWhenReported: false)
        #expect(next)
    }

    @Test func otherButtonsCloseThePanelAtOnce() {
        var outside = Outside()
        let right = outside.otherButton()
        #expect(right)
        // Even during a press of the left button that is still waiting for its release.
        let press = outside.click(heldWhenReported: true)
        let rightDuringPress = outside.otherButton(leftButtonHeld: true)
        #expect(!press && rightDuringPress && !outside.isWaiting)
    }

    /// Releases that end clicks in the panel itself are not about closing it.
    @Test func aReleaseWithNothingWaitingDoesNothing() {
        var outside = Outside()
        let beside = outside.release(at: besideThePanel)
        let over = outside.release(at: overThePanel)
        #expect(!beside && !over)
    }
}

struct EscapeActionTests {
    private let question = ConfirmationRequest(title: "Remove “Timer”?", confirmTitle: "Remove")
    private let progress = ConfirmationRequest(title: "Setting up Toolsy’s helper…", confirmTitle: "", isProgress: true)

    @Test func escapeUndoesTheInnermostThing() {
        #expect(EscapeAction(composingText: false, dialog: question, isEditing: true, keepOpen: false) == .cancelDialog)
        #expect(EscapeAction(composingText: false, dialog: nil, isEditing: true, keepOpen: false) == .stopEditing)
        #expect(EscapeAction(composingText: false, dialog: nil, isEditing: false, keepOpen: false) == .closePanel)
    }

    @Test func workInProgressAndAPanelKeptOpenStay() {
        #expect(EscapeAction(composingText: false, dialog: progress, isEditing: false, keepOpen: false) == .ignore)
        #expect(EscapeAction(composingText: false, dialog: nil, isEditing: false, keepOpen: true) == .ignore)
        #expect(EscapeAction(composingText: false, dialog: question, isEditing: false, keepOpen: true) == .cancelDialog)
    }

    /// An input method composing text in a field (kana before conversion, an accent held down): Esc cancels
    /// the composition, and nothing else.
    @Test func textBeingComposedKeepsItsEscape() {
        for dialog in [nil, question, progress] {
            for isEditing in [false, true] {
                #expect(EscapeAction(composingText: true, dialog: dialog, isEditing: isEditing, keepOpen: false) == .passOn)
            }
        }
    }
}
