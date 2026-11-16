import AppKit

/// Where the panel's window sits on screen for one presentation: under the status item, from the menu
/// bar down to the bottom of the screen. The window is transparent and lets clicks through wherever
/// the panel does not draw, so it can be as tall as the panel may ever grow, and the panel changes
/// its height inside it. The frame is decided when the panel opens and kept until it closes:
///
/// - The status item moves on its own (macOS places a new item a moment after launch, other items
///   come and go, the menu bar of a full-screen space slides away once the pointer leaves it). A
///   panel that kept following it jumped sideways the next time its height changed.
/// - Resizing the window while the content animates cuts the animation at the old window edge, and
///   the glass reaches newly exposed parts of a window a few frames after the content does, so a
///   page that grew showed its lower rows on the bare desktop for a moment.
struct PanelPlacement: Equatable {
    static let width = Metrics.panelWidth + 2 * Metrics.panelInset

    /// Leading edge of the window.
    let x: CGFloat
    /// Top edge of the window: just under the menu bar.
    let top: CGFloat
    /// The tallest the panel's content may be on this screen.
    let maxContentHeight: CGFloat

    /// `anchor` is the frame of the status item to hang under, already known to sit in the menu bar of
    /// the screen (`isInMenuBar`); without one the panel goes to the top right of the screen.
    init(anchor: NSRect?, visibleFrame: NSRect) {
        // Like a menu, the panel's leading edge lines up with the status item, and it is kept on
        // screen. The inset leaves room for the glass rim, so the window may touch the screen edge.
        let wanted = (anchor?.minX ?? visibleFrame.maxX) - Metrics.panelInset
        x = min(max(wanted, visibleFrame.minX), visibleFrame.maxX - Self.width)
        top = min(anchor?.minY ?? .infinity, visibleFrame.maxY) - 2
        maxContentHeight = max(200, top - visibleFrame.minY - 2 * Metrics.panelInset)
    }

    /// The window's frame: room for the tallest panel.
    var frame: NSRect {
        let height = maxContentHeight + 2 * Metrics.panelInset
        return NSRect(x: x, y: top - height, width: Self.width, height: height)
    }

    /// Whether a status item's window is where the user sees the item: touching the top edge of its
    /// screen. An item macOS has not placed yet lies elsewhere, and so does one whose menu bar is
    /// hidden (it waits above the screen); neither says where the panel belongs.
    static func isInMenuBar(_ item: NSRect, of screenFrame: NSRect) -> Bool {
        item.maxY >= screenFrame.maxY - 1 && item.minY < screenFrame.maxY
    }
}
