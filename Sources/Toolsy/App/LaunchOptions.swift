import AppKit
import ToolsyShared

/// Debug launch arguments, used for automated screenshots:
///
///     --open                 open the panel at launch
///     --keep-open            never close the panel on focus loss, outside clicks or Esc
///     --page <name>          start on a page: root, settings or mod:<id> (debug builds: also gallery)
///     --appearance <name>    force light or dark for this app only
///     --simulate-no-battery  show the dashboard of a Mac without a battery
///
/// Debug builds only, for testing without touching the user's mods, helper or login items:
///
///     --data-root <folder>   keep mods, state and data in <folder> instead of Application Support;
///                            also leaves the login item alone
///     --simulate-helper      an in-memory administrator helper that runs "privileged" commands as
///                            the current user and never shows the administrator prompt
///     --script <file>        run a scripted session (see DebugScript); the panel never becomes key
///                            unless the script asks for typing
///     --update-feed <folder> look for updates in <folder> instead of on GitHub (see DebugUpdateFeed)
struct LaunchOptions {
    var openAtLaunch = false
    var keepOpen = false
    var startPage: PanelPage?
    var appearance: NSAppearance.Name?
    var simulateNoBattery = false
    #if DEBUG
    var dataRoot: URL?
    var simulateHelper = false
    var script: URL?
    var updateFeed: URL?
    #endif

    /// Unknown `--` arguments are reported on stderr and otherwise ignored; arguments AppKit
    /// adds itself (`-NS…`, `-psn_…`) start with a single dash and are left alone.
    init(arguments: [String]) {
        var remaining = arguments.dropFirst()[...]
        while let argument = remaining.popFirst() {
            switch argument {
            case "--open": openAtLaunch = true
            case "--keep-open": keepOpen = true
            case "--simulate-no-battery": simulateNoBattery = true
            case "--page":
                switch remaining.popFirst() {
                case "root": startPage = .root
                case "settings": startPage = .settings
                #if DEBUG
                case "gallery": startPage = .gallery
                #endif
                case let page? where page.hasPrefix("mod:"): startPage = .mod(String(page.dropFirst(4)))
                case let other: Self.warn("--page expects root, settings or mod:<id>, got \(other ?? "nothing")")
                }
            case "--appearance":
                switch remaining.popFirst() {
                case "light": appearance = .aqua
                case "dark": appearance = .darkAqua
                case let other: Self.warn("--appearance expects light or dark, got \(other ?? "nothing")")
                }
            #if DEBUG
            case "--data-root":
                if let path = remaining.popFirst() {
                    dataRoot = URL(filePath: path, directoryHint: .isDirectory).standardizedFileURL
                } else {
                    Self.warn("--data-root expects a folder")
                }
            case "--simulate-helper": simulateHelper = true
            case "--script":
                if let path = remaining.popFirst() {
                    script = URL(filePath: path).standardizedFileURL
                } else {
                    Self.warn("--script expects a file")
                }
            case "--update-feed":
                if let path = remaining.popFirst() {
                    updateFeed = URL(filePath: path, directoryHint: .isDirectory).standardizedFileURL
                } else {
                    Self.warn("--update-feed expects a folder")
                }
            #endif
            case let other where other.hasPrefix("--"):
                Self.warn("unknown argument \(other)")
            default:
                break
            }
        }
    }

    /// Where the user's mods live; a debug run may point elsewhere.
    var directories: ToolsyDirectories {
        #if DEBUG
        if let dataRoot { return ToolsyDirectories(root: dataRoot) }
        #endif
        return .user
    }

    /// Whether this run may change the user's login items: never in a debug run on scratch data.
    var managesLoginItem: Bool {
        #if DEBUG
        return dataRoot == nil
        #else
        return true
        #endif
    }

    /// Whether this run may look for updates by itself: never in a debug run on scratch data, which must not
    /// depend on the network. Check Now works in every run.
    var checksForUpdates: Bool {
        #if DEBUG
        return dataRoot == nil
        #else
        return true
        #endif
    }

    /// The arguments that start the app again as this run was started, for the restart after an update; with
    /// `openingPanel` the panel opens at once, as it was open when the update began. A debug run keeps its scratch data
    /// and stand-ins, so the new version never touches the owner's mods.
    func relaunchArguments(openingPanel: Bool) -> [String] {
        var arguments: [String] = []
        if openingPanel { arguments.append("--open") }
        if keepOpen { arguments.append("--keep-open") }
        if let appearance { arguments += ["--appearance", appearance == .darkAqua ? "dark" : "light"] }
        if simulateNoBattery { arguments.append("--simulate-no-battery") }
        #if DEBUG
        if let dataRoot { arguments += ["--data-root", dataRoot.path(percentEncoded: false)] }
        if simulateHelper { arguments.append("--simulate-helper") }
        if let script { arguments += ["--script", script.path(percentEncoded: false)] }
        if let updateFeed { arguments += ["--update-feed", updateFeed.path(percentEncoded: false)] }
        #endif
        return arguments
    }

    private static func warn(_ message: String) {
        FileHandle.standardError.write(Data("Toolsy: \(message)\n".utf8))
    }
}
