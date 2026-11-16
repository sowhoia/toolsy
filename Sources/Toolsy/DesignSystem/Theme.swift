import SwiftUI

/// Layout constants. Spacing follows an 8-pt rhythm; radii are concentric: an inner shape's
/// radius is its container's radius minus the padding between them.
enum Metrics {
    /// Outer width of the glass panel.
    static let panelWidth: CGFloat = 352
    /// Space between the window edge and the glass, so its rim and shadow are not clipped.
    static let panelInset: CGFloat = 8
    /// Space between the glass edge and the groups inside it.
    static let panelPadding: CGFloat = 8
    static let panelRadius: CGFloat = tileRadius + panelPadding
    static let tileSpacing: CGFloat = 8
    static let tileRadius: CGFloat = 24
    static let tilePadding: CGFloat = 14
    static let innerRadius: CGFloat = tileRadius - tilePadding
    static let rowMinHeight: CGFloat = 28
    static let headerHeight: CGFloat = 40
    static let badgeSize: CGFloat = 26
    static let controlHeight: CGFloat = 28
    static let iconButtonSize: CGFloat = 30
}

/// Springs shared by every component, so the whole panel moves with one character.
enum Motion {
    static let snappy = Animation.spring(response: 0.28, dampingFraction: 0.86)
    static let gentle = Animation.spring(response: 0.42, dampingFraction: 0.9)
    static let fade = Animation.easeInOut(duration: 0.18)
    /// The give of Liquid Glass: a thumb lifting into a lens and settling back, glass swelling under a press.
    static let liquid = Animation.spring(response: 0.3, dampingFraction: 0.58)
    /// A thumb or a selection travelling to its new place.
    static let travel = Animation.spring(response: 0.32, dampingFraction: 0.78)

    /// With Reduce Motion, movement becomes a short cross-fade-like ease.
    static func resolve(_ animation: Animation, reduceMotion: Bool) -> Animation {
        reduceMotion ? fade : animation
    }
}

/// The text styles of the panel (also the `style` values of a mod's `text` control).
enum TextStyle: String, CaseIterable, Sendable {
    case title, body, caption, mono

    var font: Font {
        switch self {
        case .title: .system(size: 15, weight: .semibold)
        case .body: .system(size: 13)
        case .caption: .system(size: 11)
        case .mono: .system(size: 12, design: .monospaced)
        }
    }
}

extension Font {
    static let rowLabel = Font.system(size: 13)
    static let rowValue = Font.system(size: 13).monospacedDigit()
    static let tileTitle = Font.system(size: 12, weight: .semibold)
}
