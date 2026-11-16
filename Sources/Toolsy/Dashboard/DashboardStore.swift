import Foundation
import Observation
import os
import ToolsyShared

private let logger = Logger(subsystem: ToolsyPaths.bundleIdentifier, category: "dashboard")

/// The user's dashboard layout, saved in `Dashboard.json` in the data root after every change. One
/// instance lives for the life of the app and is in the SwiftUI environment of every page.
///
/// Loading never fails: without a file, or with one that cannot be read or comes from a newer Toolsy,
/// the dashboard shows the standard layout and the file is left alone until the user changes something.
@Observable
final class DashboardStore {
    static let version = 1

    private(set) var layout: DashboardLayout
    /// The root page shows the editing tools instead of the mods. Not saved: every opening of the
    /// panel starts out of it.
    var isEditing = false

    @ObservationIgnored let file: URL
    @ObservationIgnored private let standard: DashboardLayout

    init(file: URL, hasBattery: Bool) {
        self.file = file
        standard = .standard(hasBattery: hasBattery)
        layout = Self.load(file) ?? standard
    }

    // MARK: Changing the layout

    func contains(_ id: WidgetID) -> Bool {
        layout.widgets.contains { $0.id == id }
    }

    /// Puts the widget at the end of the dashboard, unless it is there already.
    func add(_ id: WidgetID) {
        guard !contains(id) else { return }
        change { $0.widgets.append(PlacedWidget(id: id)) }
    }

    func remove(_ id: WidgetID) {
        change { $0.widgets.removeAll { $0.id == id } }
    }

    /// Takes every widget of a mod off the dashboard, for when the mod is uninstalled.
    func removeWidgets(ofMod modID: String) {
        change { $0.widgets.removeAll { $0.id.modWidget?.modID == modID } }
    }

    /// Moves a widget so that it ends up at `index` of `layout.widgets` (clamped to the list).
    func move(_ id: WidgetID, to index: Int) {
        change { layout in
            guard let from = layout.widgets.firstIndex(where: { $0.id == id }) else { return }
            let widget = layout.widgets.remove(at: from)
            layout.widgets.insert(widget, at: min(max(index, 0), layout.widgets.count))
        }
    }

    /// Moves a widget to `position` among `shown`: the widgets the dashboard displays, in their saved
    /// order. Saved entries it does not display (a mod that is not installed) keep their places.
    func move(_ id: WidgetID, toPosition position: Int, among shown: [WidgetID]) {
        let others = shown.filter { $0 != id }
        let saved = layout.widgets.map(\.id).filter { $0 != id }
        let index: Int
        if position < others.count, let before = saved.firstIndex(of: others[max(position, 0)]) {
            index = before
        } else {
            index = others.last.flatMap { saved.firstIndex(of: $0) }.map { $0 + 1 } ?? saved.count
        }
        move(id, to: index)
    }

    func setSize(_ size: WidgetSize, of id: WidgetID) {
        update(id) { $0.size = size }
    }

    func setChartStyle(_ style: ChartStyle, of id: WidgetID) {
        update(id) { $0.chartStyle = style }
    }

    func setRateUnit(_ unit: RateUnit, of id: WidgetID) {
        update(id) { $0.rateUnit = unit }
    }

    func setShowsDeviceLine(_ shows: Bool) {
        change { $0.showsDeviceLine = shows }
    }

    /// Back to the standard layout. Saved even when nothing changed on screen, so it also replaces a
    /// file that could not be read.
    func reset() {
        layout = standard
        save()
    }

    private func update(_ id: WidgetID, _ body: (inout PlacedWidget) -> Void) {
        change { layout in
            guard let index = layout.widgets.firstIndex(where: { $0.id == id }) else { return }
            body(&layout.widgets[index])
        }
    }

    private func change(_ body: (inout DashboardLayout) -> Void) {
        var changed = layout
        body(&changed)
        guard changed != layout else { return }
        layout = changed
        save()
    }

    // MARK: File

    /// `Dashboard.json`: the layout's fields next to the version of the format.
    private struct SavedLayout: Codable {
        var version: Int
        var showsDeviceLine: Bool
        var widgets: [PlacedWidget]
    }

    private struct SavedVersion: Decodable {
        var version: Int
    }

    private func save() {
        let saved = SavedLayout(version: Self.version, showsDeviceLine: layout.showsDeviceLine, widgets: layout.widgets)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(saved).write(to: file, options: .atomic)
        } catch {
            // The layout on screen stays as the user made it; it is lost only if Toolsy quits before
            // the next change saves it.
            logger.error("Dashboard layout could not be saved to \(self.file.path(percentEncoded: false), privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The saved layout, or nil when the standard one applies. Duplicates are dropped; ids nothing can
    /// show (yet) are kept for the dashboard to skip.
    private static func load(_ file: URL) -> DashboardLayout? {
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil  // never customised
        } catch {
            logger.error("Dashboard layout \(file.path(percentEncoded: false), privacy: .public) cannot be read: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        let decoder = JSONDecoder()
        do {
            let version = try decoder.decode(SavedVersion.self, from: data).version
            guard version <= Self.version else {
                logger.notice("Dashboard layout is of a newer version (\(version)); showing the standard layout")
                return nil
            }
            let saved = try decoder.decode(SavedLayout.self, from: data)
            var seen: Set<WidgetID> = []
            return DashboardLayout(showsDeviceLine: saved.showsDeviceLine,
                                   widgets: saved.widgets.filter { seen.insert($0.id).inserted })
        } catch {
            logger.error("Dashboard layout \(file.path(percentEncoded: false), privacy: .public) is damaged: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
