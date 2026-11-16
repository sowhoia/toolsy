import SwiftUI

/// The `style` of a mod's chart.
enum ChartStyle: String, CaseIterable, Sendable {
    case line, area, bar
}

/// One line (or set of bars) of a chart: samples oldest first.
struct ChartSeries {
    var label: String?
    var tint: Color
    var values: [Double]

    init(_ label: String? = nil, tint: Color = .accentColor, values: some Collection<Double>) {
        self.label = label
        self.tint = tint
        self.values = Array(values)
    }
}

/// A fixed-length history of samples, oldest first, for feeding a chart.
struct SampleHistory: Equatable {
    let capacity: Int
    private(set) var values: [Double] = []

    init(capacity: Int) {
        self.capacity = max(2, capacity)
    }

    mutating func append(_ value: Double) {
        guard value.isFinite else { return }
        values.append(value)
        if values.count > capacity { values.removeFirst(values.count - capacity) }
    }
}

/// A line, area or bar chart of one to six series, drawn with paths (no chart framework).
///
/// The newest sample sits at the trailing edge; `capacity` samples fill the width. When a
/// series gains a sample, the plot scrolls by one step instead of jumping. The vertical range
/// is `min`/`max` where given and otherwise fitted to the data with some headroom.
struct SeriesChart: View {
    private let label: String?
    private let series: [ChartSeries]
    private let style: ChartStyle
    private let fixedMin: Double?
    private let fixedMax: Double?
    private let unit: String?
    private let capacity: Int
    private let height: CGFloat
    private let showsReadout: Bool
    private let format: ((Double) -> String)?

    init(_ label: String? = nil, series: [ChartSeries], style: ChartStyle = .line, min: Double? = nil,
         max: Double? = nil, unit: String? = nil, capacity: Int = 60, height: CGFloat = 56,
         showsReadout: Bool = true, format: ((Double) -> String)? = nil) {
        self.label = label
        self.series = series
        self.style = style
        fixedMin = min
        fixedMax = max
        self.unit = unit
        self.capacity = Swift.max(2, capacity)
        self.height = height
        self.showsReadout = showsReadout
        self.format = format
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// How many steps the plot is drawn to the right of its resting place; animated from 1 to
    /// 0 when a sample arrives. The paths are drawn once per sample and only this translation
    /// animates, so scrolling costs a layer move per frame, not a redraw.
    @State private var lag: Double = 0
    /// The sample of each series that last scrolled out on the left, drawn while it slides out.
    @State private var carried: [Double?] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if label != nil || showsReadout {
                header
            }
            plot
                .frame(height: height)
        }
        .onChange(of: series.map(\.values)) { old, new in
            advance(from: old, to: new)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label ?? String(localized: "Chart"))
        .accessibilityValue(readouts.map { [$0.label, $0.text].compactMap { $0 }.joined(separator: " ") }.joined(separator: ", "))
    }

    private var header: some View {
        HStack(spacing: 10) {
            if let label {
                Text(label).font(.tileTitle).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if showsReadout {
                ForEach(Array(readouts.enumerated()), id: \.offset) { _, readout in
                    HStack(spacing: 4) {
                        if series.count > 1 {
                            Circle().fill(readout.tint).frame(width: 6, height: 6)
                        }
                        if let seriesLabel = readout.label, series.count > 1 {
                            Text(seriesLabel).foregroundStyle(.secondary)
                        }
                        Text(readout.text)
                            .monospacedDigit()
                            // Readouts change with every sample; see the dashboard on why not numericText.
                            .contentTransition(.interpolate)
                    }
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                }
            }
        }
        .animation(Motion.snappy, value: readouts.map(\.text))
    }

    private var readouts: [(label: String?, tint: Color, text: String)] {
        series.map { item in
            (item.label, item.tint, item.values.last.map(text) ?? "—")
        }
    }

    private func text(_ value: Double) -> String {
        format?(value) ?? formatNumber(value, unit: unit)
    }

    private var bounds: ClosedRange<Double> {
        let all = series.flatMap(\.values) + carried.compactMap { $0 }
        var low = fixedMin ?? all.min() ?? 0
        var high = fixedMax ?? all.max() ?? 1
        if high <= low {
            let pad = Swift.max(abs(high) * 0.1, 1)
            if fixedMin == nil { low -= pad }
            if fixedMax == nil || high <= low { high = low + 2 * pad }
        } else {
            let pad = (high - low) * 0.12
            if fixedMin == nil { low = (low >= 0 && low - pad < 0) ? 0 : low - pad }
            if fixedMax == nil { high += pad }
        }
        // Bars need a baseline inside the range.
        if style == .bar, fixedMin == nil, low > 0 { low = 0 }
        return low...high
    }

    private var plot: some View {
        let range = bounds
        return ZStack(alignment: .bottom) {
            Hairline().opacity(0.6)
            ZStack {
                ForEach(series.indices, id: \.self) { index in
                    let item = series[index]
                    let leading = index < carried.count ? carried[index] : nil
                    switch style {
                    case .line, .area:
                        let shape = ChartLine(values: item.values, leading: leading, capacity: capacity,
                                              low: range.lowerBound, high: range.upperBound)
                        if style == .area {
                            let strength = series.count > 1 ? 0.2 : 0.32
                            shape.closed().fill(LinearGradient(colors: [item.tint.opacity(strength), item.tint.opacity(0.03)],
                                                               startPoint: .top, endPoint: .bottom))
                        }
                        shape.stroke(item.tint, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    case .bar:
                        ChartBars(values: item.values, leading: leading, capacity: capacity,
                                  low: range.lowerBound, high: range.upperBound, slot: index, slots: series.count)
                            .fill(item.tint)
                    }
                }
            }
            .modifier(ScrollEffect(steps: lag, stepsAcross: style == .bar ? capacity : capacity - 1))
            if series.allSatisfy(\.values.isEmpty) {
                Text("No data yet")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .clipped()
    }

    private func advance(from old: [[Double]], to new: [[Double]]) {
        guard let before = old.first, let after = new.first, !reduceMotion,
              Self.isAppend(before, after) else {
            // Replaced data, or Reduce Motion: redraw in place.
            carried = []
            lag = 0
            return
        }
        let dropped = before.count == after.count
        carried = old.map { dropped ? $0.first : nil }
        lag = 1
        withAnimation(.easeOut(duration: 0.55)) { lag = 0 }
    }

    /// Whether `new` is `old` plus one sample at the end (and possibly minus the oldest).
    private static func isAppend(_ old: [Double], _ new: [Double]) -> Bool {
        if new.count == old.count + 1 { return new.dropLast().elementsEqual(old) }
        if new.count == old.count, !new.isEmpty { return new.dropLast().elementsEqual(old.dropFirst()) }
        return false
    }
}

/// Moves the plot right by a number of sample steps.
private struct ScrollEffect: GeometryEffect {
    var steps: Double
    let stepsAcross: Int

    var animatableData: Double {
        get { steps }
        set { steps = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: size.width / CGFloat(stepsAcross) * steps, y: 0))
    }
}

/// Places samples on the time axis: the newest at the trailing edge, older ones one step left
/// each, the carried sample (index -1) one step before the first.
private nonisolated struct TimeAxis {
    let rect: CGRect
    let capacity: Int
    let low: Double
    let high: Double
    let valueCount: Int
    /// Bars occupy slots, lines end exactly on the edges.
    let slotted: Bool

    var step: CGFloat { slotted ? rect.width / CGFloat(capacity) : rect.width / CGFloat(capacity - 1) }

    func x(_ index: Int) -> CGFloat {
        rect.maxX - CGFloat(valueCount - 1 - index) * step - (slotted ? step / 2 : 0)
    }

    func y(_ value: Double) -> CGFloat {
        let fraction = (value - low) / max(high - low, .ulpOfOne)
        return rect.maxY - CGFloat(fraction) * rect.height
    }
}

private struct ChartLine: Shape {
    var values: [Double]
    var leading: Double?
    var capacity: Int
    var low: Double
    var high: Double
    var isClosed = false

    func closed() -> ChartLine {
        var copy = self
        copy.isClosed = true
        return copy
    }

    func path(in rect: CGRect) -> Path {
        let axis = TimeAxis(rect: rect, capacity: capacity, low: low, high: high, valueCount: values.count, slotted: false)
        var points = values.indices.map { CGPoint(x: axis.x($0), y: axis.y(values[$0])) }
        if let leading { points.insert(CGPoint(x: axis.x(-1), y: axis.y(leading)), at: 0) }
        guard let first = points.first, let last = points.last else { return Path() }
        var path = Path()
        path.move(to: first)
        for point in points.dropFirst() { path.addLine(to: point) }
        if isClosed {
            path.addLine(to: CGPoint(x: last.x, y: rect.maxY + 1))
            path.addLine(to: CGPoint(x: first.x, y: rect.maxY + 1))
            path.closeSubpath()
        }
        return path
    }
}

private struct ChartBars: Shape {
    var values: [Double]
    var leading: Double?
    var capacity: Int
    var low: Double
    var high: Double
    var slot: Int
    var slots: Int

    func path(in rect: CGRect) -> Path {
        let axis = TimeAxis(rect: rect, capacity: capacity, low: low, high: high, valueCount: values.count, slotted: true)
        let groupWidth = axis.step * 0.72
        let width = max(1, groupWidth / CGFloat(slots) - (slots > 1 ? 1 : 0))
        let baseline = axis.y(min(max(0, low), high))
        var path = Path()
        var bars = values.indices.map { ($0, values[$0]) }
        if let leading { bars.insert((-1, leading), at: 0) }
        for (index, value) in bars {
            let x = axis.x(index) - groupWidth / 2 + CGFloat(slot) * (groupWidth / CGFloat(slots))
            let y = axis.y(value)
            let bar = CGRect(x: x, y: min(y, baseline), width: width, height: max(abs(baseline - y), 1))
            path.addRoundedRect(in: bar, cornerSize: CGSize(width: min(2, width / 2), height: min(2, width / 2)))
        }
        return path
    }
}
