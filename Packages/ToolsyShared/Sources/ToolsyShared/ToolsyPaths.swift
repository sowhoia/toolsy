import Foundation

public enum ToolsyPaths {
    public static let bundleIdentifier = "app.toolsy"
    /// Extension of a packed mod: a zip archive with `mod.json` at its root.
    public static let modFileExtension = "toolsymod"
}

/// Where the app keeps a user's mods. Tests point `root` at a temporary directory.
public struct ToolsyDirectories: Sendable, Equatable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// `~/Library/Application Support/Toolsy`
    public static var user: ToolsyDirectories {
        ToolsyDirectories(root: URL.applicationSupportDirectory.appending(path: "Toolsy", directoryHint: .isDirectory))
    }

    /// One unpacked directory per installed mod, named by mod id.
    public var mods: URL {
        root.appending(path: "Mods", directoryHint: .isDirectory)
    }

    /// One `<id>.json` per mod: its persisted settings and on/off state.
    public var state: URL {
        root.appending(path: "State", directoryHint: .isDirectory)
    }

    /// One writable directory per mod, handed to its commands as `TOOLSY_DATA_DIR`.
    public var data: URL {
        root.appending(path: "Data", directoryHint: .isDirectory)
    }

    /// One file per mod installed from a signed package, named by mod id: the public key that signed it,
    /// so that an update signed by another key, or not signed at all, stands out.
    public var signers: URL {
        root.appending(path: "Signers", directoryHint: .isDirectory)
    }
}
