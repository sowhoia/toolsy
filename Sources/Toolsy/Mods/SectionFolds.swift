import Observation
import SwiftUI
import ToolsyShared

/// Which collapsible sections of mods the user folded or unfolded (MOD_FORMAT.md, "Layout"). Kept for
/// as long as the app runs, so the choice survives leaving the page, closing the panel and state
/// patches; not saved to disk. A section the user has not touched follows its manifest's `collapsed`.
@Observable
final class SectionFolds {
    /// A section of a mod: where its controls are shown and its index path there.
    struct Key: Hashable {
        var modID: String
        var place: ModControlPlace
        var path: [Int]
    }

    private var folded: [Key: Bool] = [:]

    func isFolded(_ key: Key, section: ModControl.Section) -> Bool {
        section.collapsible && (folded[key] ?? section.collapsed)
    }

    func setFolded(_ isFolded: Bool, _ key: Key) {
        folded[key] = isFolded
    }

    /// Drops what was chosen for a mod's sections, for when the mod is removed.
    func forget(modID: String) {
        folded = folded.filter { $0.key.modID != modID }
    }
}

/// Where a mod's controls are shown: its page (`ui`), or the `detail` of one of its widgets. Two places
/// can hold different sections at the same index path.
enum ModControlPlace: Hashable {
    case page
    case widgetDetail(String)
}

extension EnvironmentValues {
    /// Set by the view that shows a widget's `detail`; the page is the default.
    @Entry var modControlPlace = ModControlPlace.page
}
