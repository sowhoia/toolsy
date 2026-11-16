import Foundation
import Testing
import ToolsyEngine
import ToolsyShared
@testable import Toolsy

// MARK: - Widget ids

struct WidgetIDTests {
    @Test func builtInIdsAreTheMetricNames() {
        for metric in SystemMetric.allCases {
            #expect(WidgetID.builtIn(metric).rawValue == metric.rawValue)
            #expect(WidgetID(rawValue: metric.rawValue).metric == metric)
            #expect(WidgetID.builtIn(metric).modWidget == nil)
        }
    }

    @Test func modWidgetIdsRoundTrip() throws {
        let id = WidgetID.mod("net.ping-2", widget: "latency_ms")
        #expect(id.rawValue == "mod:net.ping-2/latency_ms")
        let parts = try #require(id.modWidget)
        #expect(parts.modID == "net.ping-2")
        #expect(parts.widgetID == "latency_ms")
        #expect(id.metric == nil)
    }

    @Test func otherTextNamesNothing() {
        for raw in ["", "mod:", "mod:ping", "mod:/latency", "mod:ping/", "ping/latency", "warp-drive", "CPU"] {
            let id = WidgetID(rawValue: raw)
            #expect(id.modWidget == nil, "\(raw)")
            #expect(id.metric == nil, "\(raw)")
        }
    }

    @Test func manifestSizesMapOntoColumns() {
        for size in ModWidget.Size.allCases {
            #expect(WidgetSize(size).columns == size.columns)
        }
    }
}

// MARK: - Packing

struct GridPackingTests {
    private func rows(_ spans: [Int]) -> [[Int]] {
        let slots = GridPacking.pack(spans)
        return (0..<GridPacking.rowCount(slots)).map { row in slots.filter { $0.row == row }.map(\.span) }
    }

    @Test func emptyLayoutHasNoRows() {
        #expect(GridPacking.pack([]).isEmpty)
        #expect(GridPacking.rowCount([]) == 0)
    }

    @Test func standardLayoutsLookAsBefore() {
        // CPU, memory, battery / network, storage.
        #expect(rows([1, 1, 1, 2, 1]) == [[1, 1, 1], [2, 1]])
        // Without a battery: CPU, memory, storage / network across the whole row.
        #expect(rows([1, 1, 1, 2]) == [[1, 1, 1], [3]])
    }

    @Test func lastTileOfAnUnfilledRowStretches() {
        #expect(rows([1]) == [[3]])
        #expect(rows([1, 1]) == [[1, 2]])
        #expect(rows([2]) == [[3]])
        #expect(rows([2, 2]) == [[3], [3]])
        #expect(rows([1, 3, 1]) == [[3], [3], [3]])
        #expect(rows([1, 1, 2, 1]) == [[1, 2], [2, 1]])
        #expect(rows([2, 1, 2, 1, 1]) == [[2, 1], [2, 1], [3]])
    }

    @Test func outOfRangeSpansAreClamped() {
        #expect(rows([0, 7]) == [[3], [3]])
        #expect(rows([-1, 1, 1]) == [[1, 1, 1]])
    }

    /// Every sequence of up to six tiles: rows are full, nothing overlaps, order is kept, a tile only
    /// grows when it ends its row, and a row closes only when the next tile does not fit.
    @Test func everyCombinationFillsItsRows() {
        func sequences(_ length: Int) -> [[Int]] {
            length == 0 ? [[]] : sequences(length - 1).flatMap { prefix in (1...3).map { prefix + [$0] } }
        }
        for length in 0...6 {
            for spans in sequences(length) {
                let slots = GridPacking.pack(spans)
                #expect(slots.count == spans.count)
                var expected = (row: 0, column: 0)
                for (index, slot) in slots.enumerated() {
                    if slot.row != expected.row {
                        #expect(slot.row == expected.row + 1, "\(spans)")
                        #expect(expected.column == 0 || expected.column == GridPacking.columns, "\(spans)")
                        expected = (slot.row, 0)
                    }
                    #expect(slot.column == expected.column, "\(spans)")
                    #expect(slot.span >= spans[index], "\(spans)")
                    expected.column += slot.span
                    let endsRow = index == slots.count - 1 || slots[index + 1].row != slot.row
                    if endsRow {
                        #expect(expected.column == GridPacking.columns, "\(spans)")
                        if index < slots.count - 1 {
                            // The next tile did not fit next to what the row wanted.
                            let wanted = slots.indices.filter { slots[$0].row == slot.row }.map { spans[$0] }.reduce(0, +)
                            #expect(wanted + spans[index + 1] > GridPacking.columns, "\(spans)")
                        }
                    } else {
                        #expect(slot.span == spans[index], "\(spans)")
                    }
                }
            }
        }
    }

    @Test func slotsHaveFramesInTheGrid() {
        let geometry = GridGeometry(width: 336, tileHeight: 70, spacing: 8)
        #expect(geometry.columnWidth == 320.0 / 3)
        let frame = geometry.frame(of: GridSlot(row: 1, column: 1, span: 2))
        #expect(frame.minX == 320.0 / 3 + 8)
        #expect(frame.minY == 78)
        #expect(frame.maxX == 336)
        #expect(frame.height == 70)
        #expect(geometry.height(rows: 0) == 0)
        #expect(geometry.height(rows: 2) == 148)
    }

    @Test func aDraggedTileLandsUnderThePointer() {
        let geometry = GridGeometry(width: 336, tileHeight: 70, spacing: 8)
        let spans = [1, 1, 1, 2, 1]  // CPU, memory, battery / network, storage
        // CPU onto storage: it takes storage's slot and storage moves on to a row of its own.
        #expect(GridPacking.dropIndex(of: 0, spans: spans, at: CGPoint(x: 300, y: 110), in: geometry) == 3)
        // Resting where it was: stays.
        #expect(GridPacking.dropIndex(of: 0, spans: spans, at: CGPoint(x: 40, y: 30), in: geometry) == 0)
        // Storage onto the battery slot.
        #expect(GridPacking.dropIndex(of: 4, spans: spans, at: CGPoint(x: 300, y: 30), in: geometry) == 2)
        // Far below the grid: the nearest slot, the end.
        #expect(GridPacking.dropIndex(of: 1, spans: spans, at: CGPoint(x: 300, y: 900), in: geometry) == 4)
    }
}

// MARK: - Store

@MainActor
private final class DashboardFolder {
    let root = FileManager.default.temporaryDirectory.appending(path: "ToolsyDashboard-\(UUID().uuidString)", directoryHint: .isDirectory)
    var file: URL { root.appending(path: "Dashboard.json") }

    func store(hasBattery: Bool = true) -> DashboardStore {
        DashboardStore(file: file, hasBattery: hasBattery)
    }

    func write(_ text: String) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }

    func contents() throws -> String {
        try String(contentsOf: file, encoding: .utf8)
    }

    var exists: Bool {
        FileManager.default.fileExists(atPath: file.path(percentEncoded: false))
    }

    deinit {
        try? FileManager.default.removeItem(at: root)  // best effort: a temporary folder
    }
}

@MainActor
struct DashboardStoreTests {
    private func ids(_ store: DashboardStore) -> [String] {
        store.layout.widgets.map(\.id.rawValue)
    }

    @Test func standardLayoutDependsOnTheBattery() {
        let folder = DashboardFolder()
        #expect(ids(folder.store(hasBattery: true)) == ["cpu", "memory", "battery", "network", "storage"])
        #expect(ids(folder.store(hasBattery: false)) == ["cpu", "memory", "storage", "network"])
        #expect(folder.store().layout.widgets.first { $0.id == .builtIn(.network) }?.size == .medium)
        #expect(folder.store().layout.showsDeviceLine)
        #expect(!folder.exists, "nothing is written before the user changes something")
    }

    @Test func changesAreSavedAndLoadedAgain() throws {
        let folder = DashboardFolder()
        let store = folder.store()
        store.add(.builtIn(.gpu))
        store.add(.mod("ping", widget: "latency"))
        store.setSize(.wide, of: .builtIn(.gpu))
        store.setChartStyle(.bar, of: .builtIn(.cpu))
        store.setRateUnit(.bits, of: .builtIn(.network))
        store.move(.builtIn(.storage), to: 0)
        store.setShowsDeviceLine(false)
        let reloaded = folder.store()
        #expect(reloaded.layout == store.layout)
        #expect(ids(reloaded) == ["storage", "cpu", "memory", "battery", "network", "gpu", "mod:ping/latency"])
        #expect(!reloaded.layout.showsDeviceLine)
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.file)) as? [String: Any]
        #expect(saved?["version"] as? Int == DashboardStore.version)
    }

    @Test func addIsANoOpForAPlacedWidget() {
        let folder = DashboardFolder()
        let store = folder.store()
        store.setSize(.wide, of: .builtIn(.cpu))
        store.add(.builtIn(.cpu))
        #expect(ids(store) == ["cpu", "memory", "battery", "network", "storage"])
        #expect(store.layout.widgets[0].size == .wide)
        #expect(store.contains(.builtIn(.cpu)))
        #expect(!store.contains(.builtIn(.gpu)))
    }

    @Test func removingWidgets() {
        let folder = DashboardFolder()
        let store = folder.store()
        store.add(.mod("ping", widget: "a"))
        store.add(.mod("ping", widget: "b"))
        store.add(.mod("ping-pong", widget: "a"))
        store.remove(.builtIn(.memory))
        store.removeWidgets(ofMod: "ping")
        #expect(ids(store) == ["cpu", "battery", "network", "storage", "mod:ping-pong/a"])
        store.remove(.builtIn(.gpu))  // not placed: nothing happens
        #expect(ids(store).count == 5)
    }

    @Test func movingClampsAndKeepsHiddenEntriesInPlace() {
        let folder = DashboardFolder()
        let store = folder.store()
        store.move(.builtIn(.cpu), to: 99)
        #expect(ids(store) == ["memory", "battery", "network", "storage", "cpu"])
        store.move(.builtIn(.cpu), to: -3)
        #expect(ids(store) == ["cpu", "memory", "battery", "network", "storage"])
        store.move(.builtIn(.gpu), to: 0)  // not placed
        #expect(ids(store).count == 5)

        // A widget of a mod that is not installed sits between memory and battery; the dashboard
        // shows the others and moves among them.
        store.add(.mod("gone", widget: "w"))
        store.move(.mod("gone", widget: "w"), to: 2)
        let shown: [WidgetID] = [.builtIn(.cpu), .builtIn(.memory), .builtIn(.battery), .builtIn(.network), .builtIn(.storage)]
        store.move(.builtIn(.cpu), toPosition: 2, among: shown)
        #expect(ids(store) == ["memory", "mod:gone/w", "battery", "cpu", "network", "storage"])
        store.move(.builtIn(.storage), toPosition: 0, among: [.builtIn(.memory), .builtIn(.battery), .builtIn(.cpu), .builtIn(.network), .builtIn(.storage)])
        #expect(ids(store) == ["storage", "memory", "mod:gone/w", "battery", "cpu", "network"])
        store.move(.builtIn(.storage), toPosition: 4, among: [.builtIn(.storage), .builtIn(.memory), .builtIn(.battery), .builtIn(.cpu), .builtIn(.network)])
        #expect(ids(store) == ["memory", "mod:gone/w", "battery", "cpu", "network", "storage"])
    }

    @Test func resetRestoresTheStandardLayout() {
        let folder = DashboardFolder()
        let store = folder.store(hasBattery: false)
        store.remove(.builtIn(.cpu))
        store.setShowsDeviceLine(false)
        store.reset()
        #expect(store.layout == .standard(hasBattery: false))
        #expect(folder.store(hasBattery: false).layout == .standard(hasBattery: false))
    }

    @Test func damagedFileFallsBackUntilTheUserChangesSomething() throws {
        let folder = DashboardFolder()
        for damaged in ["{not json", #"{"version": 1, "widgets": "cpu"}"#, #"{"version": 1, "showsDeviceLine": true, "widgets": [{"id": "cpu", "size": "huge"}]}"#, "[]"] {
            try folder.write(damaged)
            let store = folder.store()
            #expect(store.layout == .standard(hasBattery: true), "\(damaged)")
            #expect(try folder.contents() == damaged, "the file is left alone")
            store.add(.builtIn(.gpu))
            #expect(ids(folder.store()) == ["cpu", "memory", "battery", "network", "storage", "gpu"])
        }
    }

    @Test func newerFileIsNotOverwrittenUntilAChange() throws {
        let folder = DashboardFolder()
        let newer = #"{"version": 2, "showsDeviceLine": false, "widgets": [{"id": "cpu"}], "pages": 3}"#
        try folder.write(newer)
        let store = folder.store()
        #expect(store.layout == .standard(hasBattery: true))
        #expect(try folder.contents() == newer)
        store.setShowsDeviceLine(false)
        #expect(!folder.store().layout.showsDeviceLine)
    }

    @Test func unknownIdsAreKeptAndDuplicatesDropped() throws {
        let folder = DashboardFolder()
        try folder.write("""
        {"version": 1, "showsDeviceLine": true, "widgets": [
          {"id": "gpu", "size": "medium", "chartStyle": "bar"}, {"id": "mod:gone/w"}, {"id": "warp-drive"},
          {"id": "gpu", "size": "small"}, {"id": "cpu"}, {"id": "mod:gone/w"}
        ]}
        """)
        let store = folder.store()
        #expect(ids(store) == ["gpu", "mod:gone/w", "warp-drive", "cpu"])
        #expect(store.layout.widgets[0] == PlacedWidget(id: .builtIn(.gpu), size: .medium, chartStyle: .bar))
        store.remove(.builtIn(.cpu))
        #expect(ids(folder.store()) == ["gpu", "mod:gone/w", "warp-drive"])
    }
}

// MARK: - Availability

@MainActor
struct WidgetAvailabilityTests {
    @Test func metricsTheMacLacksAreNotOffered() {
        let withoutBattery = Set(SystemMetric.allCases).subtracting([.battery])
        let offered = WidgetInfo.available(metrics: withoutBattery, mods: []).map(\.id)
        #expect(offered == [.builtIn(.cpu), .builtIn(.memory), .builtIn(.network), .builtIn(.storage), .builtIn(.gpu), .builtIn(.disk)])
        #expect(!DashboardLayout.standard(hasBattery: false).widgets.contains { $0.id == .builtIn(.battery) })
    }

    @Test func modWidgetsAreOfferedAndResolved() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "ToolsyWidgets-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }  // best effort: a temporary folder
        let directories = ToolsyDirectories(root: root)
        let folder = directories.mods.appending(path: "ping", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("""
        {"schema": 1, "id": "ping", "name": "Ping", "version": "1", "icon": "bolt", "tint": "teal",
         "widgets": [
           {"id": "latency", "title": "Latency", "value": "{{ms}}", "size": "medium",
            "chart": {"series": [{"bind": "ms"}], "style": "bar"}},
           {"id": "loss", "value": "{{loss}}", "gauge": {"bind": "loss"}}
         ]}
        """.utf8).write(to: folder.appending(path: "mod.json"))
        let model = ModsModel(store: ModStore(directories: directories, privileged: SimulatedHelper(store: root.appending(path: "helper"))),
                              directories: directories, panel: PanelState())
        model.start()
        await model.waitUntilStarted()
        #expect(model.store.loadProblems.isEmpty)

        let offered = WidgetInfo.available(metrics: [.cpu], mods: model.store.mods)
        #expect(offered.map(\.id) == [.builtIn(.cpu), .mod("ping", widget: "latency"), .mod("ping", widget: "loss")])

        let latency = try #require(WidgetInfo.resolve(.mod("ping", widget: "latency"), metrics: [], mods: model))
        #expect(latency.name == "Latency")
        #expect(latency.symbol == "bolt")
        #expect(latency.source == "Ping")
        #expect(latency.defaultSize == .medium)
        #expect(latency.defaultChartStyle == .bar)
        let loss = try #require(WidgetInfo.resolve(.mod("ping", widget: "loss"), metrics: [], mods: model))
        #expect(loss.name == "Ping", "without a title, the mod's name")
        #expect(loss.defaultSize == .small)
        #expect(loss.defaultChartStyle == nil)

        #expect(WidgetInfo.resolve(.mod("ping", widget: "jitter"), metrics: [], mods: model) == nil)
        #expect(WidgetInfo.resolve(.mod("gone", widget: "latency"), metrics: [], mods: model) == nil)
        #expect(WidgetInfo.resolve(.builtIn(.battery), metrics: [.cpu], mods: model) == nil)
        #expect(WidgetInfo.resolve(WidgetID(rawValue: "warp-drive"), metrics: Set(SystemMetric.allCases), mods: model) == nil)
        await model.shutdown(within: .seconds(5))
    }
}

// MARK: - GPU and disk readings on this Mac

struct GPUAndDiskReadingTests {
    @Test func gpuUtilisationIsReported() throws {
        let reader = try #require(GPUReader(), "IOAccelerator publishes PerformanceStatistics on Apple silicon")
        let reading = try #require(reader.read())
        #expect((0...1).contains(reading.utilization))
        #expect(reading.renderer.map { (0...1).contains($0) } ?? true)
        #expect((reading.memoryInUse ?? 0) >= 0)
        #expect(reader.model?.isEmpty == false)
    }

    @Test func diskRatesNeedABaselineAndAreSane() throws {
        let counters = DiskActivitySampler.readCounters()
        #expect(!counters.isEmpty, "the internal disk reports its statistics")
        #expect(counters.values.contains { $0.read > 0 }, "the system has read from its disk since startup")
        let sampler = DiskActivitySampler()
        #expect(sampler.sample() == nil)
        Thread.sleep(forTimeInterval: 0.2)
        let activity = try #require(sampler.sample())
        #expect(activity.readRate >= 0 && activity.readRate < 20e9)
        #expect(activity.writeRate >= 0 && activity.writeRate < 20e9)
        #expect(activity.totalRead >= counters.values.map(\.read).reduce(0, +))
    }

    @Test func bitRatesUseDecimalBits() {
        #expect(Format.bitRate(150_000).contains(1.2.formatted(.number.precision(.fractionLength(1)))))
        #expect(Format.bitRate(0) != Format.rate(0))
    }
}
