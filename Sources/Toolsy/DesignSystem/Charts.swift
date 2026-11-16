import AppKit
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
/// series gains a sample, the plot slides by one step instead of jumping. The vertical range
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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if label != nil || showsReadout {
                header
            }
            plot
                .frame(height: height)
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
                            .tickingValue()
                    }
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                }
            }
        }
    }

    private var readouts: [(label: String?, tint: Color, text: String)] {
        series.map { item in
            (item.label, item.tint, item.values.last.map(text) ?? "—")
        }
    }

    private func text(_ value: Double) -> String {
        format?(value) ?? formatNumber(value, unit: unit)
    }

    private var plot: some View {
        ZStack(alignment: .bottom) {
            Hairline().opacity(0.6)
            PlotLayers(series: series, style: style, capacity: capacity, fixedMin: fixedMin, fixedMax: fixedMax)
                // A chart is only looked at: clicks belong to the tile or row it sits in.
                .allowsHitTesting(false)
            if series.allSatisfy(\.values.isEmpty) {
                Text("No data yet")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

// MARK: Plot

/// What a plot draws: the samples of every series, oldest first, and where they go.
struct PlotData: Equatable {
    var values: [[Double]] = []
    /// Per series, the sample that just left the plot on the left, drawn while it slides out.
    var carried: [Double?] = []
    var style = ChartStyle.line
    var capacity = 2
    var fixedMin: Double?
    var fixedMax: Double?

    /// Whether `new` is `old` plus one sample at the end (and possibly minus the oldest): the plot
    /// then slides by one step. Anything else is other data and is drawn in place.
    static func isAppend(_ old: [Double], _ new: [Double]) -> Bool {
        if new.count == old.count + 1 { return new.dropLast().elementsEqual(old) }
        if new.count == old.count, !new.isEmpty { return new.dropLast().elementsEqual(old.dropFirst()) }
        return false
    }

    /// Takes new samples. Returns whether they continue the old ones by one step; the samples that
    /// dropped out on the left are then carried, so the lines do not end short while they slide.
    mutating func advance(to new: [[Double]]) -> Bool {
        defer { values = new }
        guard let before = values.first, let after = new.first, Self.isAppend(before, after) else {
            carried = []
            return false
        }
        carried = values.map { before.count == after.count ? $0.first : nil }
        return true
    }

    /// The vertical range: `fixedMin`/`fixedMax` where given, otherwise fitted with some headroom.
    var range: ClosedRange<Double> {
        let all = values.joined() + carried.compactMap(\.self)
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

    /// The distance between two samples in a plot `width` wide: bars occupy slots, lines end exactly on
    /// the edges.
    func step(width: CGFloat) -> CGFloat {
        width / CGFloat(style == .bar ? capacity : capacity - 1)
    }

    /// Where the samples of series `index` go in `rect`: the newest at the trailing edge, older ones one
    /// step left each, the carried sample one step before the first.
    func points(ofSeries index: Int, in rect: CGRect) -> [CGPoint] {
        let samples = values[index]
        let step = step(width: rect.width), range = range
        func point(_ position: Int, _ value: Double) -> CGPoint {
            let fraction = (value - range.lowerBound) / Swift.max(range.upperBound - range.lowerBound, .ulpOfOne)
            return CGPoint(x: rect.maxX - CGFloat(samples.count - 1 - position) * step - (style == .bar ? step / 2 : 0),
                           y: rect.maxY - CGFloat(fraction) * rect.height)
        }
        let leading = index < carried.count ? carried[index].map { [point(-1, $0)] } ?? [] : []
        return leading + samples.indices.map { point($0, samples[$0]) }
    }

    /// The line through the samples of a series; `closed` down to the bottom edge for the area under it.
    func line(ofSeries index: Int, in rect: CGRect, closed: Bool = false) -> CGPath {
        let points = points(ofSeries: index, in: rect)
        let path = CGMutablePath()
        guard let first = points.first, let last = points.last else { return path }
        path.addLines(between: points)
        if closed {
            path.addLine(to: CGPoint(x: last.x, y: rect.maxY))
            path.addLine(to: CGPoint(x: first.x, y: rect.maxY))
            path.closeSubpath()
        }
        return path
    }

    /// One bar per sample; the series of a chart stand side by side within a step.
    func bars(ofSeries index: Int, in rect: CGRect) -> CGPath {
        let step = step(width: rect.width), range = range, slots = CGFloat(values.count)
        let groupWidth = step * 0.72
        let width = Swift.max(1, groupWidth / slots - (slots > 1 ? 1 : 0))
        let zero = Swift.min(Swift.max(0, range.lowerBound), range.upperBound)
        let baseline = rect.maxY - CGFloat((zero - range.lowerBound) / Swift.max(range.upperBound - range.lowerBound, .ulpOfOne)) * rect.height
        let path = CGMutablePath()
        for point in points(ofSeries: index, in: rect) {
            let bar = CGRect(x: point.x - groupWidth / 2 + CGFloat(index) * (groupWidth / slots), y: Swift.min(point.y, baseline),
                             width: width, height: Swift.max(abs(baseline - point.y), 1))
            let corner = Swift.min(2, width / 2, bar.height / 2)
            path.addRoundedRect(in: bar, cornerWidth: corner, cornerHeight: corner)
        }
        return path
    }
}

/// The plot of a `SeriesChart` as Core Animation layers, so that the slide of an arriving sample is run
/// by the render server. SwiftUI would drive it from this process, a transaction per frame: with two
/// sparklines sliding for half of every second, the open panel never came to rest.
private struct PlotLayers: NSViewRepresentable {
    let series: [ChartSeries]
    let style: ChartStyle
    let capacity: Int
    let fixedMin: Double?
    let fixedMax: Double?

    func makeNSView(context: Context) -> PlotView {
        PlotView()
    }

    func updateNSView(_ view: PlotView, context: Context) {
        view.show(series.map(\.values), tints: series.map { NSColor($0.tint) }, style: style, capacity: capacity,
                  fixedMin: fixedMin, fixedMax: fixedMax, slides: !context.environment.accessibilityReduceMotion)
    }
}

private final class PlotView: NSView {
    /// The layers of one series: the line or bars, and the gradient under an area's line.
    private struct Marks {
        let shape = CAShapeLayer()
        let area = CAGradientLayer()
        let areaShape = CAShapeLayer()

        init() {
            shape.lineWidth = 1.5
            shape.lineCap = .round
            shape.lineJoin = .round
            area.mask = areaShape
        }
    }

    private var data = PlotData()
    private var tints: [NSColor] = []
    private var marks: [Marks] = []
    /// Holds every mark and slides as a whole. It reaches one step beyond the view's leading edge,
    /// where the carried samples are drawn until they have slid out.
    private let canvas = CALayer()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.addSublayer(canvas)
    }

    required init?(coder: NSCoder) {
        fatalError("not used from a nib")
    }

    // Top-left origin, like the SwiftUI views around it.
    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func show(_ values: [[Double]], tints: [NSColor], style: ChartStyle, capacity: Int, fixedMin: Double?, fixedMax: Double?,
              slides: Bool) {
        var next = data
        next.style = style
        next.capacity = capacity
        next.fixedMin = fixedMin
        next.fixedMax = fixedMax
        let continues = next.advance(to: values)
        guard next != data || tints != self.tints else { return }
        data = next
        self.tints = tints
        draw()
        if continues, slides, bounds.width > 0 {
            let slide = CABasicAnimation(keyPath: "transform.translation.x")
            slide.fromValue = data.step(width: bounds.width)
            slide.toValue = 0
            slide.duration = 0.55
            slide.timingFunction = CAMediaTimingFunction(name: .easeOut)
            canvas.add(slide, forKey: "slide")
        }
    }

    override func layout() {
        super.layout()
        draw()
    }

    // Colours are resolved for the appearance, shapes rendered for the screen's scale.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        draw()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        draw()
    }

    private func draw() {
        // Layers that back no view animate every change by themselves; these changes are the data.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        while marks.count < data.values.count {
            let added = Marks()
            canvas.addSublayer(added.area)
            canvas.addSublayer(added.shape)
            marks.append(added)
        }
        for removed in marks.dropFirst(data.values.count) {
            removed.area.removeFromSuperlayer()
            removed.shape.removeFromSuperlayer()
        }
        marks.removeLast(marks.count - data.values.count)

        let step = bounds.width > 0 ? data.step(width: bounds.width) : 0
        canvas.frame = CGRect(x: -step, y: 0, width: bounds.width + step, height: bounds.height)
        let rect = CGRect(x: step, y: 0, width: bounds.width, height: bounds.height)
        let scale = window?.backingScaleFactor ?? 2
        effectiveAppearance.performAsCurrentDrawingAppearance {
            for (index, mark) in marks.enumerated() {
                let tint = index < tints.count ? tints[index] : .controlAccentColor
                for layer in [mark.shape, mark.area, mark.areaShape] {
                    layer.frame = canvas.bounds
                    layer.contentsScale = scale
                }
                mark.area.isHidden = data.style != .area
                switch data.style {
                case .bar:
                    mark.shape.path = data.bars(ofSeries: index, in: rect)
                    mark.shape.fillColor = tint.cgColor
                    mark.shape.strokeColor = nil
                case .line, .area:
                    mark.shape.path = data.line(ofSeries: index, in: rect)
                    mark.shape.fillColor = nil
                    mark.shape.strokeColor = tint.cgColor
                    if data.style == .area {
                        let strength = data.values.count > 1 ? 0.2 : 0.32
                        mark.area.colors = [tint.withAlphaComponent(strength).cgColor, tint.withAlphaComponent(0.03).cgColor]
                        mark.areaShape.path = data.line(ofSeries: index, in: rect, closed: true)
                    }
                }
            }
        }
    }
}
