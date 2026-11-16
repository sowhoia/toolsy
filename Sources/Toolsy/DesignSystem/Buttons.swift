import SwiftUI

/// The `style` of a mod's button.
enum ButtonKind: String, CaseIterable, Sendable {
    case normal, prominent, destructive
}

/// A capsule button on Liquid Glass. `isBusy` shows a spinner and makes it inert while its
/// action is running.
struct GlassButton: View {
    private let title: String
    private let icon: String?
    private let kind: ButtonKind
    private let tint: Color
    private let isBusy: Bool
    private let fillsWidth: Bool
    private let action: () -> Void

    /// `tint` colours a prominent button.
    init(_ title: String, icon: String? = nil, kind: ButtonKind = .normal, tint: Color = .accentColor,
         isBusy: Bool = false, fillsWidth: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.kind = kind
        self.tint = tint
        self.isBusy = isBusy
        self.fillsWidth = fillsWidth
        self.action = action
    }

    var body: some View {
        Button(role: kind == .destructive ? .destructive : nil, action: action) {
            // In a narrow column (three buttons in a row) the label keeps its words and drops the icon.
            ViewThatFits(in: .horizontal) {
                label(showsIcon: true)
                label(showsIcon: false)
            }
            .font(.system(size: 13, weight: kind == .prominent ? .semibold : .regular))
            .frame(maxWidth: fillsWidth ? .infinity : nil)
            .frame(height: Metrics.controlHeight)
            .padding(.horizontal, 12)
        }
        .buttonStyle(LiquidGlassButtonStyle(shape: Capsule(), tint: kind == .prominent ? tint : nil,
                                            foreground: kind == .destructive ? .red : nil, pressedScale: 1.04))
        .disabled(isBusy)
        .accessibilityValue(isBusy ? String(localized: "In progress") : "")
    }

    /// The full label must fit as it is to be chosen; the last fallback shrinks, then truncates.
    private func label(showsIcon: Bool) -> some View {
        HStack(spacing: 6) {
            if isBusy {
                ProgressView().controlSize(.small)
            } else if showsIcon, let icon {
                SymbolImage(icon).imageScale(.medium)
            }
            if showsIcon {
                Text(title).lineLimit(1).fixedSize()
            } else {
                Text(title).lineLimit(1).minimumScaleFactor(0.8)
            }
        }
    }
}

/// A round button of Liquid Glass with a symbol, for headers and toolbars.
struct IconButton: View {
    private let symbol: String
    private let label: String
    private let action: () -> Void

    init(_ symbol: String, label: String, action: @escaping () -> Void) {
        self.symbol = symbol
        self.label = label
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            SymbolImage(symbol)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: Metrics.iconButtonSize, height: Metrics.iconButtonSize)
        }
        .buttonStyle(LiquidGlassButtonStyle(shape: Circle(), pressedScale: 1.1))
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Liquid Glass as iOS 26 draws a button: clear glass, or tinted glass for a prominent one. Light
/// gathers where the pointer is; under a press the glass swells and brightens, and it springs back
/// on release.
private struct LiquidGlassButtonStyle<S: InsettableShape>: ButtonStyle {
    let shape: S
    var tint: Color?
    /// The label colour of clear glass; nil for the primary colour.
    var foreground: Color?
    let pressedScale: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        LiquidGlassButtonBody(configuration: configuration, style: self)
    }

    fileprivate struct LiquidGlassButtonBody: View {
        let configuration: Configuration
        let style: LiquidGlassButtonStyle
        @State private var pointer: CGPoint?
        @State private var size: CGSize = .zero
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.colorScheme) private var colorScheme

        var body: some View {
            let pressed = configuration.isPressed
            configuration.label
                .foregroundStyle(labelColor)
                .contentShape(style.shape)
                .background {
                    GlassChip(shape: style.shape, tint: style.tint, isHovered: pointer != nil && isEnabled,
                              isPressed: pressed, glow: glow)
                }
                .onGeometryChange(for: CGSize.self, of: { $0.size }) { size = $0 }
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point): pointer = point
                    case .ended: pointer = nil
                    }
                }
                .scaleEffect(pressed && !reduceMotion ? style.pressedScale : 1)
                .opacity(isEnabled ? 1 : 0.45)
                .animation(Motion.liquid, value: pressed)
                .animation(Motion.fade, value: pointer == nil)
                .contentShape(.focusEffect, style.shape)
        }

        private var glow: UnitPoint? {
            guard let pointer, size.width > 0, size.height > 0 else { return nil }
            return UnitPoint(x: pointer.x / size.width, y: pointer.y / size.height)
        }

        private var labelColor: Color {
            if let tint = style.tint {
                return tint.prefersDarkLabel(in: colorScheme) ? .black : .white
            }
            return style.foreground ?? .primary
        }
    }
}

/// An SF Symbol that falls back to a neutral glyph when the name (often from a mod manifest)
/// does not exist, instead of rendering nothing.
struct SymbolImage: View {
    private let name: String

    init(_ name: String) {
        self.name = name
    }

    var body: some View {
        Image(systemName: Self.exists(name) ? name : "questionmark.square.dashed")
            .symbolRenderingMode(.hierarchical)
    }

    private static var known: [String: Bool] = [:]

    private static func exists(_ name: String) -> Bool {
        if let cached = known[name] { return cached }
        let exists = NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
        known[name] = exists
        return exists
    }
}
