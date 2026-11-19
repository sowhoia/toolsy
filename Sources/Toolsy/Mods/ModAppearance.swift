import SwiftUI
import ToolsyEngine
import ToolsyShared

/// What the panel calls a mod and how it draws it: the look the user gave it over the manifest's own.
struct ModAppearance: Equatable {
    var name: String
    var symbol: String
    var tint: Color
    /// The manifest's name, shown beside a name of the user's own.
    let originalName: String

    static let defaultSymbol = "puzzlepiece.extension.fill"

    init(manifest: ModManifest, look: ModLook = ModLook()) {
        originalName = manifest.name
        name = look.name ?? manifest.name
        symbol = look.icon ?? manifest.icon ?? Self.defaultSymbol
        tint = Tint.resolve(look.tint) ?? Tint.color(manifest.tint)
    }

    var isRenamed: Bool { name != originalName }
}

extension ModsModel {
    func appearance(of mod: Mod) -> ModAppearance {
        ModAppearance(manifest: mod.manifest, look: preferences.look(of: mod.id))
    }
}

extension EnvironmentValues {
    /// The colour of the mod whose controls are shown: the tint of its sliders, buttons, gauges and charts unless a
    /// control names its own.
    @Entry var modTint: Color = .accentColor
}
