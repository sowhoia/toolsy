import SwiftUI

/// Formats a control's number: as many decimals as the step needs (none for whole steps), in
/// the user's locale, followed by the unit as the manifest wrote it (`"%"`, `" ms"`).
func formatNumber(_ value: Double, step: Double? = nil, unit: String? = nil) -> String {
    let decimals: Int
    if let step, step > 0, step.rounded() != step {
        // The fewest decimals that write the step exactly (0.25 → 2, 0.5 → 1), at most 4.
        decimals = (1...4).first { places in
            let scaled = step * pow(10, Double(places))
            return abs(scaled - scaled.rounded()) < 1e-9
        } ?? 4
    } else if step == nil, value.rounded() != value {
        decimals = abs(value) < 10 ? 2 : 1
    } else {
        decimals = 0
    }
    return value.formatted(.number.precision(.fractionLength(decimals))) + (unit ?? "")
}

/// The iOS 26 slider: a thin track filled with the tint and a capsule thumb that lifts into a lens of
/// clear glass while it is dragged. Arrow keys move it by one step when focused.
///
/// `onChange` runs on every change while dragging (a mod's `live` slider); `onCommit` runs
/// once when the value settles (release, click, key press).
struct GlassSlider: View {
    @Binding private var value: Double
    private let range: ClosedRange<Double>
    private let step: Double?
    private let tint: Color
    private let label: String
    private let onChange: ((Double) -> Void)?
    private let onCommit: ((Double) -> Void)?

    init(value: Binding<Double>, in range: ClosedRange<Double>, step: Double? = nil, tint: Color = .accentColor,
         label: String, onChange: ((Double) -> Void)? = nil, onCommit: ((Double) -> Void)? = nil) {
        _value = value
        self.range = range
        self.step = step
        self.tint = tint
        self.label = label
        self.onChange = onChange
        self.onCommit = onCommit
    }

    private static let thumb = CGSize(width: 30, height: 20)
    /// How far the lens reaches past the resting thumb on each side.
    private static let lensGrowth = CGSize(width: 7, height: 5)
    private static let trackHeight: CGFloat = 6
    private static let height: CGFloat = 28

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isDragging = false
    @GestureState private var gestureIsActive = false
    @State private var isHovered = false
    /// How much wider the lens is from the speed of the drag.
    @State private var stretch: CGFloat = 0

    private var span: Double { max(range.upperBound - range.lowerBound, .ulpOfOne) }
    private var fraction: Double { min(max((value - range.lowerBound) / span, 0), 1) }

    var body: some View {
        GeometryReader { proxy in
            let travel = max(proxy.size.width - Self.thumb.width, 1)
            let x = travel * fraction
            LensedScene(lens: thumbFrame(at: x), lift: isDragging && !reduceMotion ? 1 : 0, magnification: 1.35, knob: true) {
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.14)).frame(height: Self.trackHeight)
                    Capsule().fill(tint).frame(width: Self.thumb.width / 2 + x, height: Self.trackHeight)
                }
                .frame(width: proxy.size.width, height: Self.height)
            }
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($gestureIsActive) { _, active, _ in active = true }
                    .onChanged { drag in
                        isDragging = true
                        let x = drag.location.x - Self.thumb.width / 2
                        update(to: range.lowerBound + span * Double(min(max(x / travel, 0), 1)))
                        withAnimation(.interactiveSpring(response: 0.18, dampingFraction: 0.86)) {
                            stretch = reduceMotion ? 0 : min(abs(drag.velocity.width) / 2400, 0.22)
                        }
                    }
                    .onEnded { _ in end() },
                isEnabled: isEnabled
            )
        }
        .frame(height: Self.height)
        .opacity(isEnabled ? 1 : 0.4)
        .brightness(isHovered && isEnabled ? 0.03 : 0)
        .onHover { isHovered = $0 }
        .animation(Motion.resolve(Motion.liquid, reduceMotion: reduceMotion), value: isDragging)
        .animation(Motion.fade, value: isHovered)
        .onChange(of: gestureIsActive) { _, active in
            if !active, isDragging { end() }  // cancelled: the panel closed mid-drag
        }
        .focusable(isEnabled, interactions: .activate)
        .onKeyPress(keys: [.leftArrow, .rightArrow, .downArrow, .upArrow]) { press in
            nudge(up: press.key == .rightArrow || press.key == .upArrow)
            return .handled
        }
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(formatNumber(value, step: step))
        .accessibilityAdjustableAction { direction in
            nudge(up: direction == .increment)
        }
    }

    /// At rest the thumb sits on the track; lifted, it is the lens around that place, stretched.
    private func thumbFrame(at x: CGFloat) -> CGRect {
        let rest = CGRect(x: x, y: (Self.height - Self.thumb.height) / 2, width: Self.thumb.width, height: Self.thumb.height)
        guard isDragging, !reduceMotion else { return rest }
        let width = (rest.width + 2 * Self.lensGrowth.width) * (1 + stretch)
        let height = (rest.height + 2 * Self.lensGrowth.height) * (1 - 0.4 * stretch)
        return CGRect(x: rest.midX - width / 2, y: rest.midY - height / 2, width: width, height: height)
    }

    private func end() {
        isDragging = false
        stretch = 0
        onCommit?(value)
    }

    private func nudge(up: Bool) {
        let amount = step ?? span / 20
        withAnimation(Motion.snappy) { update(to: value + (up ? amount : -amount)) }
        onCommit?(value)
    }

    private func update(to raw: Double) {
        var new = min(max(raw, range.lowerBound), range.upperBound)
        if let step, step > 0 {
            new = range.lowerBound + ((new - range.lowerBound) / step).rounded() * step
            new = min(new, range.upperBound)
        }
        guard new != value else { return }
        value = new
        onChange?(new)
    }
}

/// A slider with its label and current value: the `slider` control of a mod.
struct SliderRow: View {
    private let label: String
    private let icon: String?
    @Binding private var value: Double
    private let range: ClosedRange<Double>
    private let step: Double?
    private let unit: String?
    private let tint: Color
    private let onChange: ((Double) -> Void)?
    private let onCommit: ((Double) -> Void)?

    init(_ label: String, icon: String? = nil, value: Binding<Double>, in range: ClosedRange<Double>,
         step: Double? = nil, unit: String? = nil, tint: Color = .accentColor,
         onChange: ((Double) -> Void)? = nil, onCommit: ((Double) -> Void)? = nil) {
        self.label = label
        self.icon = icon
        _value = value
        self.range = range
        self.step = step
        self.unit = unit
        self.tint = tint
        self.onChange = onChange
        self.onCommit = onCommit
    }

    private var displayStep: Double {
        let span = range.upperBound - range.lowerBound
        return span >= 20 ? 1 : span >= 2 ? 0.1 : 0.01
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                ControlLabel(label, icon: icon)
                Spacer(minLength: 8)
                // Without a step the value is continuous; show it to a sensible precision.
                Text(formatNumber(value, step: step ?? displayStep, unit: unit))
                    .font(.rowValue)
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText(value: value))
                    .animation(Motion.snappy, value: value)
            }
            GlassSlider(value: $value, in: range, step: step, tint: tint, label: label,
                        onChange: onChange, onCommit: onCommit)
        }
    }
}

/// A number with − and + buttons: the `stepper` control of a mod.
struct StepperRow: View {
    private let label: String
    private let icon: String?
    @Binding private var value: Double
    private let range: ClosedRange<Double>?
    private let step: Double
    private let unit: String?
    private let onCommit: ((Double) -> Void)?
    @Environment(\.isEnabled) private var isEnabled

    init(_ label: String, icon: String? = nil, value: Binding<Double>, in range: ClosedRange<Double>? = nil,
         step: Double = 1, unit: String? = nil, onCommit: ((Double) -> Void)? = nil) {
        self.label = label
        self.icon = icon
        _value = value
        self.range = range
        self.step = step
        self.unit = unit
        self.onCommit = onCommit
    }

    var body: some View {
        HStack(spacing: 8) {
            ControlLabel(label, icon: icon)
            Spacer(minLength: 8)
            HStack(spacing: 2) {
                StepButton(symbol: "minus", label: String(localized: "Decrease")) { change(by: -step) }
                    .disabled(range.map { value <= $0.lowerBound } ?? false)
                Text(formatNumber(value, step: step, unit: unit))
                    .font(.rowValue)
                    .foregroundStyle(isEnabled ? .primary : .tertiary)
                    .frame(minWidth: 36)
                    .contentTransition(.numericText(value: value))
                    .animation(Motion.snappy, value: value)
                StepButton(symbol: "plus", label: String(localized: "Increase")) { change(by: step) }
                    .disabled(range.map { value >= $0.upperBound } ?? false)
            }
            .padding(2)
            .background { GlassChip(shape: Capsule()) }
        }
        .frame(minHeight: Metrics.rowMinHeight)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
        .accessibilityValue(formatNumber(value, step: step, unit: unit))
        .accessibilityAdjustableAction { direction in
            change(by: direction == .increment ? step : -step)
        }
    }

    private func change(by delta: Double) {
        var new = value + delta
        if let range { new = min(max(new, range.lowerBound), range.upperBound) }
        guard new != value else { return }
        value = new
        onCommit?(new)
    }
}

private struct StepButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .frame(width: 26, height: 24)
        }
        .buttonStyle(StepButtonStyle())
        .accessibilityLabel(label)
    }
}

private struct StepButtonStyle: ButtonStyle {
    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isEnabled ? .primary : .tertiary)
            .background {
                Capsule().fill(Color.primary.opacity(configuration.isPressed ? 0.18 : isHovered && isEnabled ? 0.09 : 0))
            }
            .contentShape(.capsule)
            .contentShape(.focusEffect, .capsule)
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(Motion.snappy, value: configuration.isPressed)
            .animation(Motion.fade, value: isHovered)
            .onHover { isHovered = $0 }
    }
}
