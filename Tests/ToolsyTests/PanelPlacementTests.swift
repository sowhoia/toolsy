import AppKit
import Testing
@testable import Toolsy

/// A 1470 × 956 pt display with a 33 pt menu bar and a Dock at the bottom.
@Suite struct PanelPlacementTests {
    private let screen = NSRect(x: 0, y: 0, width: 1470, height: 956)
    private let visible = NSRect(x: 0, y: 70, width: 1470, height: 853)
    private func item(x: CGFloat, y: CGFloat = 923) -> NSRect { NSRect(x: x, y: y, width: 32, height: 33) }

    @Test func hangsUnderTheStatusItem() {
        let placement = PanelPlacement(anchor: item(x: 869), visibleFrame: visible)
        #expect(placement.x == 869 - Metrics.panelInset)
        #expect(placement.top == 921)
    }

    /// The window reaches from under the menu bar to the bottom of the screen, whatever the panel shows.
    @Test func theWindowHasRoomForTheTallestPanel() {
        let placement = PanelPlacement(anchor: item(x: 869), visibleFrame: visible)
        #expect(placement.maxContentHeight == 921 - 70 - 2 * Metrics.panelInset)
        #expect(placement.frame == NSRect(x: 861, y: 70, width: 368, height: 851))
    }

    @Test func staysOnScreenNearTheEdges() {
        #expect(PanelPlacement(anchor: item(x: 1440), visibleFrame: visible).x == 1470 - PanelPlacement.width)
        #expect(PanelPlacement(anchor: item(x: 2), visibleFrame: visible).x == 0)
    }

    @Test func withoutAnItemItGoesToTheTopRight() {
        let placement = PanelPlacement(anchor: nil, visibleFrame: visible)
        #expect(placement.x == 1470 - PanelPlacement.width)
        #expect(placement.top == 921)
    }

    /// A screen too small for the panel still leaves it something to scroll in.
    @Test func aTinyScreenStillGivesThePanelRoom() {
        #expect(PanelPlacement(anchor: nil, visibleFrame: NSRect(x: 0, y: 0, width: 800, height: 120)).maxContentHeight == 200)
    }

    @Test func onlyAnItemAtTheTopOfItsScreenIsInTheMenuBar() {
        #expect(PanelPlacement.isInMenuBar(item(x: 869), of: screen))
        // Not placed by macOS yet.
        #expect(!PanelPlacement.isInMenuBar(item(x: 0, y: 0), of: screen))
        // The menu bar of a full-screen space is hidden: the item waits above the screen.
        #expect(!PanelPlacement.isInMenuBar(item(x: 869, y: 956), of: screen))
    }

    /// In a full-screen space the visible frame reaches the top of the screen; while the menu bar is
    /// pulled down the panel still opens under the item, not over it.
    @Test func hangsUnderARevealedMenuBar() {
        #expect(PanelPlacement.isInMenuBar(item(x: 869), of: screen))
        #expect(PanelPlacement(anchor: item(x: 869), visibleFrame: screen).top == 921)
    }
}
