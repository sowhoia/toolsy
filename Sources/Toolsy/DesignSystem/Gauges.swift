import AppKit
import SwiftUI

private func fraction(_ value: Double, in range: ClosedRange<Double>) -> Double {
    let span = range.upperBound - range.lowerBound
    guard span > 0, value.isFinite else { return 0 }
    return min(max((value - range.lowerBound) / span, 0), 1)
}

/// A horizontal level bar with label and value text: a mod's `gauge` with style `bar`.
struct BarGauge: View {
    private let label: String?
    private let icon: String?
    private let value: Double
    private let range: ClosedRange<Double>
    private let text: String
    private let tint: Color
    private let updatesOften: Bool

    /// `updatesOften` is for values fed on a schedule (a mod's service): the text then changes at once
    /// instead of rolling its digits, which redraws glyphs on the CPU for every frame of every change.
    init(_ label: String? = nil, icon: String? = nil, value: Double, in range: ClosedRange<Double> = 0...100,
         text: String, tint: Color = .accentColor, updatesOften: Bool = false) {
        self.label = label
        self.icon = icon
        self.value = value
        self.range = range
        self.text = text
        self.tint = tint
        self.updatesOften = updatesOften
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if label != nil || !text.isEmpty {
                HStack {
                    if let label { ControlLabel(label, icon: icon) }
                    Spacer(minLength: 8)
                    Text(text)
                        .font(.rowValue)
                        .foregroundStyle(.secondary)
                        .contentTransition(updatesOften ? .identity : .numericText(value: value))
                }
            }
            LevelBar(fraction: fraction(value, in: range), tint: tint)
        }
        .animation(updatesOften ? nil : Motion.gentle, value: value)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label ?? "")
        .accessibilityValue(text)
    }
}

/// The bare bar of a gauge.
struct LevelBar: View {
    let fraction: Double
    var tint: Color = .accentColor
    var height: CGFloat = 6

    var body: some View {
        GaugeFill(form: .bar, fraction: fraction, tint: tint)
            .frame(height: height)
    }
}

/// A ring that fills clockwise from the top, with text in its centre: a mod's `gauge` with
/// style `ring`, and the dashboard's rings.
struct RingGauge: View {
    private let value: Double
    private let range: ClosedRange<Double>
    private let text: String
    private let tint: Color
    private let size: CGFloat
    private let label: String?
    private let updatesOften: Bool

    /// `updatesOften`: see `BarGauge`.
    init(value: Double, in range: ClosedRange<Double> = 0...100, text: String, tint: Color = .accentColor,
         size: CGFloat = 52, label: String? = nil, updatesOften: Bool = false) {
        self.value = value
        self.range = range
        self.text = text
        self.tint = tint
        self.size = size
        self.label = label
        self.updatesOften = updatesOften
    }

    var body: some View {
        let lineWidth = max(4, size * 0.11)
        VStack(spacing: 6) {
            ZStack {
                GaugeFill(form: .ring(lineWidth: lineWidth), fraction: fraction(value, in: range), tint: tint)
                Text(text)
                    .font(.system(size: size * 0.24, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .padding(lineWidth + 2)
                    .contentTransition(updatesOften ? .identity : .numericText(value: value))
            }
            .frame(width: size, height: size)
            if let label {
                Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .animation(updatesOften ? nil : Motion.gentle, value: value)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label ?? "")
        .accessibilityValue(text)
    }
}

// MARK: Fill

/// The track and fill of a gauge as Core Animation layers, so that the fill's way to a new value is
/// animated by the render server. SwiftUI would drive it from this process, a transaction per frame, and
/// gauges fed every second would keep the panel animating without rest.
private struct GaugeFill: NSViewRepresentable {
    enum Form: Equatable {
        /// A capsule that fills from its leading end.
        case bar
        /// A circle that fills clockwise from the top.
        case ring(lineWidth: CGFloat)
    }

    let form: Form
    let fraction: Double
    let tint: Color

    func makeNSView(context: Context) -> GaugeFillView {
        GaugeFillView()
    }

    func updateNSView(_ view: GaugeFillView, context: Context) {
        view.show(form, fraction: fraction, tint: NSColor(tint), animated: !context.environment.accessibilityReduceMotion)
    }
}

private final class GaugeFillView: NSView {
    private let track = CAShapeLayer()
    private let fill = CAShapeLayer()
    private var form = GaugeFill.Form.bar
    private var fraction: Double?
    private var tint = NSColor.controlAccentColor

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        for shape in [track, fill] {
            shape.fillColor = nil
            shape.lineCap = .round
            layer?.addSublayer(shape)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("not used from a nib")
    }

    // Top-left origin, like the SwiftUI views around it.
    override var isFlipped: Bool { true }

    // A gauge is only looked at: clicks belong to the row or tile it sits in.
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func show(_ form: GaugeFill.Form, fraction: Double, tint: NSColor, animated: Bool) {
        let moves = animated && self.fraction != nil && form == self.form && fraction != self.fraction
        guard form != self.form || fraction != self.fraction || tint != self.tint else { return }
        self.form = form
        self.fraction = fraction
        self.tint = tint
        draw(animated: moves)
    }

    override func layout() {
        super.layout()
        draw(animated: false)
    }

    // Colours are resolved for the appearance, shapes rendered for the screen's scale.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        draw(animated: false)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        draw(animated: false)
    }

    private func draw(animated: Bool) {
        // Layers that back no view animate every change by themselves; only the fill's way to a new
        // value is meant to be seen.
        CATransaction.begin()
        defer { CATransaction.commit() }
        if animated {
            CATransaction.setAnimationDuration(0.45)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        } else {
            CATransaction.setDisableActions(true)
        }

        let fraction = fraction ?? 0
        let path = CGMutablePath()
        let lineWidth: CGFloat
        var end = fraction
        switch form {
        case .bar:
            // A line with round caps is a capsule; its caps make even the smallest value a full dot.
            lineWidth = bounds.height
            let length = Swift.max(bounds.width - lineWidth, 0)
            path.move(to: CGPoint(x: lineWidth / 2, y: bounds.midY))
            path.addLine(to: CGPoint(x: lineWidth / 2 + length, y: bounds.midY))
            end = length > 0 ? Swift.max(0, (bounds.width * fraction - lineWidth) / length) : 0
        case .ring(let width):
            lineWidth = width
            let radius = Swift.max((Swift.min(bounds.width, bounds.height) - lineWidth) / 2, 0)
            // Angles grow clockwise in a view whose origin is at the top.
            path.addArc(center: CGPoint(x: bounds.midX, y: bounds.midY), radius: radius,
                        startAngle: -.pi / 2, endAngle: 1.5 * .pi, clockwise: false)
        }
        let scale = window?.backingScaleFactor ?? 2
        effectiveAppearance.performAsCurrentDrawingAppearance {
            for shape in [track, fill] {
                shape.frame = bounds
                shape.contentsScale = scale
                shape.path = path
                shape.lineWidth = lineWidth
            }
            track.strokeColor = NSColor.labelColor.withAlphaComponent(0.12).cgColor
            fill.strokeColor = tint.cgColor
        }
        fill.strokeEnd = end
        fill.opacity = fraction > 0 ? 1 : 0
    }
}
