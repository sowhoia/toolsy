import Foundation

/// The `mod.json` at the root of every mod. The format is specified in `docs/MOD_FORMAT.md`.
public struct ModManifest: Decodable, Sendable, Equatable {
    public static let supportedSchema = 1
    public static let fileName = "mod.json"

    public var schema: Int
    public var id: String
    public var name: String
    public var version: String
    /// The oldest Toolsy the mod works with, such as `1.1`; older versions of Toolsy ignore the field.
    public var toolsy: String?
    public var author: String?
    public var summary: String?
    /// SF Symbol name.
    public var icon: String?
    /// Colour name, level name or `#RRGGBB`.
    public var tint: String?
    public var homepage: String?
    /// Persisted, user-editable values and their defaults.
    public var settings: ModState
    public var commands: [String: ModCommand]
    public var lifecycle: ModLifecycle
    public var ui: [ModControl]
    /// Tiles the mod offers for the dashboard.
    public var widgets: [ModWidget]
    /// Buttons, toggles and pickers the mod puts next to its name: on its card in the list, in its context menu and
    /// in the menu of Toolsy's menu bar icon.
    public var quick: [ModControl]
    /// The language the manifest's own text is written in, a lowercase BCP 47 code; `en` unless stated.
    /// A user who prefers it is shown the manifest as written, whatever `localizations` offers.
    public var language: String
    /// Language code (`ru`, `pt-br`) → source string, exactly as written in the manifest → translation.
    /// Applied by `localized(for:)`.
    public var localizations: [String: [String: String]]

    /// Whether any command runs as root, i.e. the mod needs the privileged helper and the user's approval.
    public var requiresPrivileges: Bool {
        commands.values.contains(where: \.privileged)
    }

    private enum CodingKeys: String, CodingKey {
        case schema, id, name, version, toolsy, author, summary, icon, tint, homepage, settings, commands, lifecycle, ui, widgets, quick, language, localizations
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schema = try container.decode(Int.self, forKey: .schema)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        version = try container.decode(String.self, forKey: .version)
        toolsy = try container.decodeIfPresent(String.self, forKey: .toolsy)
        author = try container.decodeIfPresent(String.self, forKey: .author)
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        icon = try container.decodeIfPresent(String.self, forKey: .icon)
        tint = try container.decodeIfPresent(String.self, forKey: .tint)
        homepage = try container.decodeIfPresent(String.self, forKey: .homepage)
        settings = try container.decodeIfPresent(ModState.self, forKey: .settings) ?? [:]
        commands = try container.decodeIfPresent([String: ModCommand].self, forKey: .commands) ?? [:]
        lifecycle = try container.decodeIfPresent(ModLifecycle.self, forKey: .lifecycle) ?? ModLifecycle()
        ui = try container.decodeIfPresent([ModControl].self, forKey: .ui) ?? []
        widgets = try container.decodeIfPresent([ModWidget].self, forKey: .widgets) ?? []
        quick = try container.decodeIfPresent([ModControl].self, forKey: .quick) ?? []
        language = try container.decodeIfPresent(String.self, forKey: .language) ?? Self.defaultLanguage
        localizations = try container.decodeIfPresent([String: [String: String]].self, forKey: .localizations) ?? [:]
    }

    /// Decodes and validates a manifest. Every failure is a `ManifestError` with a message meant for the mod author.
    public static func load(from data: Data) throws -> ModManifest {
        let manifest: ModManifest
        do {
            manifest = try JSONValue.decode(ModManifest.self, from: data)
        } catch let error as DecodingError {
            throw ManifestError(decoding: error)
        }
        try manifest.validate()
        return manifest
    }
}

/// A program a mod can run: in response to a control, as a lifecycle hook, or on a schedule.
public struct ModCommand: Decodable, Sendable, Equatable {
    public enum Program: Sendable, Equatable {
        /// A file inside the mod, started directly.
        case exec(String)
        /// A script handed to `/bin/sh -c`.
        case shell(String)
    }

    public static let defaultTimeout: Double = 30
    public static let maxTimeout: Double = 3600

    public var program: Program
    public var args: [String]
    /// Run as root through the privileged helper.
    public var privileged: Bool
    /// Send the JSON `CommandInput` on stdin.
    public var stdin: Bool
    /// Seconds before the command is killed. Does not apply to the service command.
    public var timeout: Double
    /// Store trimmed stdout as text under this state key instead of parsing it as a JSON patch.
    public var capture: String?

    private enum CodingKeys: String, CodingKey {
        case exec, shell, args, privileged, stdin, timeout, capture
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let exec = try container.decodeIfPresent(String.self, forKey: .exec)
        let shell = try container.decodeIfPresent(String.self, forKey: .shell)
        switch (exec, shell) {
        case (let exec?, nil): program = .exec(exec)
        case (nil, let shell?): program = .shell(shell)
        default:
            throw DecodingError.dataCorrupted(.init(
                codingPath: container.codingPath,
                debugDescription: "a command needs exactly one of \"exec\" and \"shell\""
            ))
        }
        args = try container.decodeIfPresent([String].self, forKey: .args) ?? []
        privileged = try container.decodeIfPresent(Bool.self, forKey: .privileged) ?? false
        stdin = try container.decodeIfPresent(Bool.self, forKey: .stdin) ?? false
        timeout = try container.decodeIfPresent(Double.self, forKey: .timeout) ?? Self.defaultTimeout
        capture = try container.decodeIfPresent(String.self, forKey: .capture)
    }
}

/// Which commands the host runs on its own, without a control asking for them.
public struct ModLifecycle: Decodable, Sendable, Equatable {
    public struct Refresh: Decodable, Sendable, Equatable {
        public var command: String
        /// Seconds between runs. Without it the command runs when the panel opens and after other commands.
        public var every: Double?
        /// Keep the schedule running while the panel is closed and the mod is on.
        public var background: Bool

        private enum CodingKeys: String, CodingKey {
            case command, every, background
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            command = try container.decode(String.self, forKey: .command)
            every = try container.decodeIfPresent(Double.self, forKey: .every)
            background = try container.decodeIfPresent(Bool.self, forKey: .background) ?? false
        }
    }

    /// Runs when the user switches the mod on.
    public var enable: String?
    /// Runs when the user switches the mod off.
    public var disable: String?
    /// Runs before the mod is removed, after `disable`.
    public var uninstall: String?
    /// Long-running command kept alive while the mod is on; every stdout line is a JSON state patch.
    public var service: String?
    public var refresh: Refresh?
    /// Commands run when something happens to the Mac, while the mod is on (always, for a mod without a switch).
    public var events: [ModSystemEvent: String]

    public init() {
        events = [:]
    }

    private enum CodingKeys: String, CodingKey {
        case enable, disable, uninstall, service, refresh, events
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enable = try container.decodeIfPresent(String.self, forKey: .enable)
        disable = try container.decodeIfPresent(String.self, forKey: .disable)
        uninstall = try container.decodeIfPresent(String.self, forKey: .uninstall)
        service = try container.decodeIfPresent(String.self, forKey: .service)
        refresh = try container.decodeIfPresent(Refresh.self, forKey: .refresh)
        events = [:]
        for (name, command) in try container.decodeIfPresent([String: String].self, forKey: .events) ?? [:] {
            guard let event = ModSystemEvent(rawValue: name) else {
                let known = ModSystemEvent.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
                throw DecodingError.dataCorruptedError(
                    forKey: .events, in: container, debugDescription: "unknown event \"\(name)\"; expected one of \(known)"
                )
            }
            events[event] = command
        }
    }

    /// Mods without any of these are passive widgets and get no main switch.
    public var hasToggle: Bool {
        enable != nil || disable != nil || service != nil
    }
}

/// State keys the host itself reads. Commands set them through their patches.
public enum ReservedStateKey {
    /// Boolean: whether the mod is on. Drives the main switch.
    public static let enabled = "enabled"
    /// Short text shown under the mod's name.
    public static let status = "status"
    /// A `ModLevel` raw value colouring the status.
    public static let level = "level"
    /// Message of the last failure; cleared by the next successful command.
    public static let error = "error"
    /// Not state: a patch that carries it asks the host to show a notification, and the key is never stored.
    public static let notify = "notify"

    public static let all: Set<String> = [enabled, status, level, error, notify]
}

public enum ModLevel: String, Sendable, CaseIterable {
    case ok, warn, error, off
}

/// One row of a `list` control, read from an element of the bound state array.
public struct ModListItem: Sendable, Equatable {
    /// Passed to the list's command as the value; defaults to the title.
    public var id: String
    public var title: String
    public var subtitle: String?
    public var value: String?
    public var icon: String?
    public var tint: String?

    /// Elements are objects (`{"title": …}`) or bare scalars, which become the title. Anything else is skipped.
    public static func items(from value: JSONValue?) -> [ModListItem] {
        (value?.arrayValue ?? []).compactMap { element in
            if element.isScalar {
                return ModListItem(id: element.text, title: element.text)
            }
            guard let object = element.objectValue, let title = object["title"]?.text, !title.isEmpty else {
                return nil
            }
            return ModListItem(
                id: object["id"]?.text ?? title,
                title: title,
                subtitle: object["subtitle"]?.text,
                value: object["value"]?.text,
                icon: object["icon"]?.stringValue,
                tint: object["tint"]?.stringValue
            )
        }
    }
}

public struct ManifestError: LocalizedError, Equatable, Sendable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }

    init(decoding error: DecodingError) {
        func located(_ context: DecodingError.Context, _ problem: String) -> String {
            var path = ""
            for key in context.codingPath {
                if let index = key.intValue {
                    path += "[\(index)]"
                } else {
                    path += path.isEmpty ? key.stringValue : ".\(key.stringValue)"
                }
            }
            return path.isEmpty ? problem : "\(path): \(problem)"
        }
        switch error {
        case .keyNotFound(let key, let context):
            self.init(located(context, "missing required field \"\(key.stringValue)\""))
        case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
            self.init(located(context, context.debugDescription))
        @unknown default:
            self.init("mod.json could not be read")
        }
    }
}
