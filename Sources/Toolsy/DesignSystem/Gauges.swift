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

    /// `updatesOften` is for values fed on a schedule (a mod's service): the text then morphs
    /// instead of rolling its digits, which blurs glyphs on the CPU with every change.
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
                        .contentTransition(updatesOften ? .interpolate : .numericText(value: value))
                }
            }
            LevelBar(fraction: fraction(value, in: range), tint: tint)
        }
        .animation(Motion.gentle, value: value)
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
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule().fill(tint)
                    .frame(width: max(height, proxy.size.width * fraction))
                    .opacity(fraction > 0 ? 1 : 0)
            }
        }
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
                Circle().stroke(Color.primary.opacity(0.12), lineWidth: lineWidth)
                Circle()
                    .trim(from: 0, to: fraction(value, in: range))
                    .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(text)
                    .font(.system(size: size * 0.24, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .padding(lineWidth + 2)
                    .contentTransition(updatesOften ? .interpolate : .numericText(value: value))
            }
            .frame(width: size, height: size)
            if let label {
                Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .animation(Motion.gentle, value: value)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label ?? "")
        .accessibilityValue(text)
    }
}
