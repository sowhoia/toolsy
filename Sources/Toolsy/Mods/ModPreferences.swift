import Foundation
import Observation
import os
import ToolsyShared

private let logger = Logger(subsystem: ToolsyPaths.bundleIdentifier, category: "mods")

/// How the list of mods on the root page is drawn.
enum ModListStyle: String, Codable, CaseIterable, Sendable {
    /// A card per mod, its status under its name.
    case cards
    /// The mods as the rows of one group, the status beside the name.
    case compact
}

/// What the user changed about how a mod looks. A field left nil follows the manifest, so an update of the mod can
/// still change it.
struct ModLook: Codable, Equatable, Sendable {
    var name: String?
    /// An SF Symbol name.
    var icon: String?
    /// A colour as `Tint` reads it: a colour name or `#RRGGBB`.
    var tint: String?

    var isEmpty: Bool { name == nil && icon == nil && tint == nil }

    /// The look as it is kept: a name on one line, trimmed and as long as a manifest's name may be; empty text is no
    /// choice at all.
    var tidied: ModLook {
        var look = self
        look.name = name.map { name in
            String(name.split(whereSeparator: \.isNewline).joined(separator: " ")
                .trimmingCharacters(in: .whitespaces).prefix(Self.maxNameLength))
        }
        if look.name?.isEmpty == true { look.name = nil }
        if look.icon?.isEmpty == true { look.icon = nil }
        if look.tint?.isEmpty == true { look.tint = nil }
        return look
    }

    /// The colours offered for a mod: the colour names `Tint` knows, in the order of the spectrum.
    static let palette = ["red", "orange", "yellow", "green", "mint", "teal", "cyan", "blue", "indigo", "purple", "pink",
                          "brown", "gray"]

    /// The icons offered for a mod, roughly by what a mod does: power and time, access, network and hardware,
    /// sound and pictures, tools, files, and a few marks.
    static let symbols = [
        "power", "bolt.fill", "moon.fill", "sun.max.fill", "cup.and.saucer.fill", "timer", "alarm.fill",
        "hourglass", "calendar", "bell.fill", "eye.fill", "lock.fill", "key.fill", "shield.lefthalf.filled",
        "network", "wifi", "globe", "antenna.radiowaves.left.and.right", "cpu", "memorychip", "internaldrive.fill",
        "display", "keyboard.fill", "headphones", "speaker.wave.2.fill", "mic.fill", "camera.fill",
        "wrench.and.screwdriver.fill", "hammer.fill", "gearshape.fill", "terminal.fill", "paintbrush.fill", "wand.and.stars",
        "slider.horizontal.3", "chart.bar.fill", "folder.fill", "doc.text.fill", "tray.full.fill", "trash.fill",
        "clipboard.fill", "bookmark.fill", "star.fill", "heart.fill", "flag.fill", "flame.fill", "leaf.fill", "drop.fill",
        "cloud.fill",
    ]

    /// The longest name kept, as long as a manifest's name may be.
    static let maxNameLength = 80
}

/// The user's arrangement of the installed mods (their order, the ones hidden from the list, the list's style) and the
/// looks they gave mods. Saved in `ModPreferences.json` in the data root after every change. One instance lives for the
/// life of the app, owned by `ModsModel`.
///
/// Loading never fails: without a file, or with one that cannot be read or comes from a newer Toolsy, the mods are
/// listed by name as cards and the file is left alone until the user changes something.
@Observable
final class ModPreferences {
    static let version = 1

    /// Mod ids in the order the user put them in. Mods missing from it follow, by name.
    private(set) var order: [String]
    private(set) var hidden: Set<String>
    private(set) var looks: [String: ModLook]
    var listStyle: ModListStyle {
        didSet { if listStyle != oldValue { save() } }
    }

    @ObservationIgnored let file: URL

    init(file: URL) {
        self.file = file
        let saved = Self.load(file)
        order = saved?.order ?? []
        hidden = saved?.hidden ?? []
        looks = saved?.looks ?? [:]
        listStyle = saved?.listStyle ?? .cards
    }

    // MARK: Order

    /// `items` in the user's order: those the user placed first, then the others by name and id.
    func arranged<Item>(_ items: [Item], id: (Item) -> String, name: (Item) -> String) -> [Item] {
        let position = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let placed = items.compactMap { item in position[id(item)].map { ($0, item) } }.sorted { $0.0 < $1.0 }.map(\.1)
        let others = items.filter { position[id($0)] == nil }.sorted {
            let (left, right) = (name($0), name($1))
            let comparison = left.localizedStandardCompare(right)
            return comparison == .orderedSame ? id($0) < id($1) : comparison == .orderedAscending
        }
        return placed + others
    }

    /// Moves a mod to `position` among `shown`: the mods as they are listed now, in this order. Mods the user never
    /// placed are placed where they are listed; ids of mods not listed (hidden, or not installed) keep their places. A
    /// mod listed alone has nothing to move past and stays.
    func move(_ id: String, toPosition position: Int, among shown: [String]) {
        guard shown.contains(id), shown.count > 1 else { return }
        var saved = order.filter { $0 != id }
        saved += shown.filter { $0 != id && !saved.contains($0) }
        let others = shown.filter { $0 != id }
        let position = min(max(position, 0), others.count)
        let index: Int
        if position < others.count, let before = saved.firstIndex(of: others[position]) {
            index = before
        } else {
            index = others.last.flatMap { saved.firstIndex(of: $0) }.map { $0 + 1 } ?? saved.count
        }
        saved.insert(id, at: index)
        change { $0.order = saved }
    }

    // MARK: Hiding

    func isHidden(_ id: String) -> Bool {
        hidden.contains(id)
    }

    func setHidden(_ isHidden: Bool, _ id: String) {
        change { preferences in
            if isHidden { preferences.hidden.insert(id) } else { preferences.hidden.remove(id) }
        }
    }

    // MARK: Looks

    func look(of id: String) -> ModLook {
        looks[id] ?? ModLook()
    }

    /// Gives a mod its look, tidied (`ModLook.tidied`). The name the mod already has (`original`) is no name of the
    /// user's.
    func setLook(_ look: ModLook, of id: String, originalName original: String) {
        var look = look.tidied
        if look.name == original { look.name = nil }
        change { $0.looks[id] = look.isEmpty ? nil : look }
    }

    // MARK: Removing a mod

    /// Drops what the user chose for a mod, for when the mod is removed: installed again, it starts afresh.
    func forget(modID: String) {
        change { preferences in
            preferences.order.removeAll { $0 == modID }
            preferences.hidden.remove(modID)
            preferences.looks[modID] = nil
        }
    }

    // MARK: File

    /// `ModPreferences.json`. Every field but the version may be missing; a list style this version does not know
    /// reads as cards.
    private struct Saved: Codable, Equatable {
        var version: Int
        var listStyle: ModListStyle
        var order: [String]
        var hidden: Set<String>
        var looks: [String: ModLook]

        private enum CodingKeys: String, CodingKey {
            case version, listStyle, order, hidden, looks
        }

        init(version: Int, listStyle: ModListStyle, order: [String], hidden: Set<String>, looks: [String: ModLook]) {
            self.version = version
            self.listStyle = listStyle
            self.order = order
            self.hidden = hidden
            self.looks = looks
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decode(Int.self, forKey: .version)
            listStyle = try container.decodeIfPresent(String.self, forKey: .listStyle).flatMap(ModListStyle.init(rawValue:)) ?? .cards
            var seen: Set<String> = []
            order = (try container.decodeIfPresent([String].self, forKey: .order) ?? []).filter { seen.insert($0).inserted }
            hidden = Set(try container.decodeIfPresent([String].self, forKey: .hidden) ?? [])
            // Tidied as `setLook` keeps them, so a hand-edited file cannot give a mod a blank name.
            looks = (try container.decodeIfPresent([String: ModLook].self, forKey: .looks) ?? [:])
                .mapValues(\.tidied).filter { !$0.value.isEmpty }
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(version, forKey: .version)
            try container.encode(listStyle, forKey: .listStyle)
            try container.encode(order, forKey: .order)
            try container.encode(hidden.sorted(), forKey: .hidden)
            try container.encode(looks, forKey: .looks)
        }
    }

    private struct SavedVersion: Decodable {
        var version: Int
    }

    private var saved: Saved {
        get { Saved(version: Self.version, listStyle: listStyle, order: order, hidden: hidden, looks: looks) }
        set {
            order = newValue.order
            hidden = newValue.hidden
            looks = newValue.looks
        }
    }

    private func change(_ body: (inout Saved) -> Void) {
        var changed = saved
        body(&changed)
        guard changed != saved else { return }
        saved = changed
        save()
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(saved).write(to: file, options: .atomic)
        } catch {
            // The choice holds for this run; only the next launch would not know it.
            logger.error("mod preferences could not be saved to \(self.file.path(percentEncoded: false), privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The saved preferences, or nil when the defaults apply.
    private static func load(_ file: URL) -> Saved? {
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil  // never changed
        } catch {
            logger.error("mod preferences \(file.path(percentEncoded: false), privacy: .public) cannot be read: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        let decoder = JSONDecoder()
        do {
            let version = try decoder.decode(SavedVersion.self, from: data).version
            guard version <= Self.version else {
                logger.notice("mod preferences are of a newer version (\(version)); using the defaults")
                return nil
            }
            return try decoder.decode(Saved.self, from: data)
        } catch {
            logger.error("mod preferences \(file.path(percentEncoded: false), privacy: .public) are damaged: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
