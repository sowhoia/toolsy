import CoreGraphics
import Testing
@testable import Toolsy

/// What a chart's plot draws and when it slides.
struct PlotDataTests {
    private let rect = CGRect(x: 10, y: 0, width: 90, height: 40)

    private func xs(_ data: PlotData, series: Int = 0) -> [CGFloat] {
        data.points(ofSeries: series, in: rect).map { $0.x.rounded() }
    }

    @Test func aSampleAtTheEndContinuesTheData() {
        #expect(PlotData.isAppend([1, 2], [1, 2, 3]), "a history that is still filling")
        #expect(PlotData.isAppend([1, 2, 3], [2, 3, 4]), "a full history drops its oldest sample")
        #expect(PlotData.isAppend([], [1]))
        for (old, new) in [([1.0, 2], [1.0, 2]), ([1, 2], [5, 6]), ([1, 2], [1, 2, 3, 4]), ([1, 2, 3], [1, 2]), ([], [])] {
            #expect(!PlotData.isAppend(old, new), "\(old) → \(new)")
        }
    }

    @Test func aFullHistoryCarriesTheSampleThatDroppedOut() {
        var data = PlotData(values: [[1, 2, 3], [7, 8, 9]], capacity: 3)
        let continues = data.advance(to: [[2, 3, 4], [8, 9, 10]])
        #expect(continues)
        #expect(data.carried == [1, 7])
        #expect(data.values == [[2, 3, 4], [8, 9, 10]])
    }

    @Test func aFillingHistoryCarriesNothing() {
        var data = PlotData(values: [[1, 2]], capacity: 4)
        let continues = data.advance(to: [[1, 2, 3]])
        #expect(continues)
        #expect(data.carried == [nil])
    }

    @Test func otherDataIsDrawnInPlace() {
        var data = PlotData(values: [[1, 2, 3]], carried: [0], capacity: 3)
        let replaced = data.advance(to: [[9, 9, 9]])
        #expect(!replaced)
        #expect(data.carried.isEmpty)
        #expect(data.values == [[9, 9, 9]])
        let emptied = data.advance(to: [])
        #expect(!emptied, "a chart that lost its series")
        let first = data.advance(to: [[1]])
        #expect(!first, "the first data of a chart")
    }

    @Test func theNewestSampleSitsAtTheTrailingEdge() {
        var data = PlotData(values: [[1, 2, 3]], capacity: 4)
        #expect(data.step(width: rect.width) == 30)
        #expect(xs(data) == [40, 70, 100], "a line ends exactly on the edge; a history that is filling starts short")
        _ = data.advance(to: [[1, 2, 3, 4]])
        #expect(xs(data) == [10, 40, 70, 100])
        _ = data.advance(to: [[2, 3, 4, 5]])
        #expect(xs(data) == [-20, 10, 40, 70, 100], "the carried sample waits one step before the leading edge")
    }

    @Test func barsStandInTheMiddleOfTheirSlots() {
        let data = PlotData(values: [[1, 2, 3]], style: .bar, capacity: 3)
        #expect(data.step(width: rect.width) == 30)
        #expect(xs(data) == [25, 55, 85])
        let bars = data.bars(ofSeries: 0, in: rect).boundingBoxOfPath
        #expect(bars.minX >= rect.minX && bars.maxX <= rect.maxX)
        #expect(bars.maxY == rect.maxY, "bars stand on the baseline")
    }

    @Test func severalSeriesShareAStep() {
        let data = PlotData(values: [[4], [4]], style: .bar, capacity: 2)
        let first = data.bars(ofSeries: 0, in: rect).boundingBoxOfPath, second = data.bars(ofSeries: 1, in: rect).boundingBoxOfPath
        #expect(first.maxX <= second.minX)
        #expect(first.width == second.width)
    }

    @Test func theRangeFitsTheDataWithHeadroom() {
        #expect(PlotData(values: [[10, 20]]).range == 8.8...21.2)
        #expect(PlotData(values: [[1, 20]]).range.lowerBound == 0, "a range that nearly reaches zero starts there")
        #expect(PlotData(values: [[10, 20]], fixedMin: 0, fixedMax: 100).range == 0...100)
        #expect(PlotData(values: [[5, 5]]).range == 4...6, "a flat line still has a range")
        let empty = PlotData(values: []).range
        #expect(empty.lowerBound == 0 && empty.upperBound > 1, "a plot without data still has a range to lay out in")
        #expect(PlotData(values: [[10, 20]], style: .bar).range.lowerBound == 0, "bars need their baseline")
        #expect(PlotData(values: [[10, 20]], carried: [40]).range.upperBound > 40, "the carried sample is still on screen")
    }

    @Test func valuesGrowUpwards() {
        let data = PlotData(values: [[0, 100]], capacity: 2, fixedMin: 0, fixedMax: 100)
        let points = data.points(ofSeries: 0, in: rect)
        #expect(points.map(\.y) == [rect.maxY, rect.minY])
        let area = data.line(ofSeries: 0, in: rect, closed: true).boundingBoxOfPath
        #expect(area == rect, "the area under a line reaches the bottom edge")
    }

    @Test func aSeriesWithoutSamplesDrawsNothing() {
        let data = PlotData(values: [[]], capacity: 4)
        #expect(data.line(ofSeries: 0, in: rect).isEmpty)
        #expect(data.bars(ofSeries: 0, in: rect).isEmpty)
    }
}
