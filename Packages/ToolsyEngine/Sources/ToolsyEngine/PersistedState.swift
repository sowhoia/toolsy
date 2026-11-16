import Foundation
import ToolsyShared

/// `State/<id>.json`: the part of a mod's state that survives restarts, `{"enabled": …, "settings": {…}}`.
struct PersistedState: Codable, Equatable {
    var enabled: Bool
    var settings: ModState

    static func file(for id: String, in directories: ToolsyDirectories) -> URL {
        directories.state.appending(path: "\(id).json")
    }

    /// The saved state over the manifest's defaults. Saved values win; settings the manifest no longer
    /// declares are dropped. Without a file the mod starts off with its defaults.
    static func load(for manifest: ModManifest, from directories: ToolsyDirectories) throws -> PersistedState {
        var saved = PersistedState(enabled: false, settings: [:])
        let url = file(for: manifest.id, in: directories)
        do {
            saved = try JSONDecoder().decode(PersistedState.self, from: Data(contentsOf: url))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            // Never saved yet.
        } catch {
            throw EngineError("State/\(url.lastPathComponent) cannot be read: \(error.localizedDescription)")
        }
        var settings = manifest.settings
        for (key, value) in saved.settings where settings[key] != nil {
            settings[key] = value
        }
        return PersistedState(enabled: saved.enabled, settings: settings)
    }

    /// Writes atomically, so a crash never leaves a half-written file behind.
    func save(for id: String, in directories: ToolsyDirectories) throws {
        try FileManager.default.createDirectory(at: directories.state, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(self).write(to: Self.file(for: id, in: directories), options: .atomic)
    }
}
