import Foundation

/// Why a command runs.
public enum ModEvent: String, Codable, Sendable {
    case enable, disable, uninstall, refresh, service
    /// Started by a control: a button, or a bound control with a `command`.
    case command
    /// Started by a system event the mod listens to (`lifecycle.events`); see `ModSystemEvent`.
    case launch, wake, network, power
}

/// Everything a command is told about its invocation. Sent as JSON on stdin when the command sets
/// `"stdin": true`, and mirrored into `TOOLSY_*` environment variables for every command.
public struct CommandInput: Codable, Sendable, Equatable {
    public var event: ModEvent
    /// Name of the command in the manifest.
    public var command: String
    /// State key of the control that triggered the command, if any.
    public var key: String?
    /// New value of that control, or a button's `value`.
    public var value: JSONValue?
    /// The mod's settings and live state at the time of the call.
    public var state: ModState
    /// The user's first preferred language as a lowercase BCP 47 code, e.g. `ru` or `en-us`; `TOOLSY_LOCALE`.
    public var locale: String?

    /// `locale` is kept as commands are told it (`languageTag`), so standard input and `TOOLSY_LOCALE` agree.
    public init(event: ModEvent, command: String, key: String? = nil, value: JSONValue? = nil, state: ModState, locale: String? = nil) {
        self.event = event
        self.command = command
        self.key = key
        self.value = value
        self.state = state
        self.locale = locale.flatMap(Self.languageTag)
    }

    /// A language as commands are told it: lowercase, and nothing at all unless it is a well-formed code.
    static func languageTag(_ language: String) -> String? {
        language.wholeMatch(of: /[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})*/) != nil ? language.lowercased() : nil
    }
}

/// What a finished command produced.
public struct CommandResult: Sendable, Equatable {
    /// Exit status, or 128 + signal number when the command was killed by a signal.
    public var exitCode: Int32
    public var stdout: Data
    public var stderr: Data
    public var timedOut: Bool

    public init(exitCode: Int32, stdout: Data = Data(), stderr: Data = Data(), timedOut: Bool = false) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
    }

    public var succeeded: Bool {
        exitCode == 0 && !timedOut
    }
}

public struct CommandInvocation: Sendable, Equatable {
    public var executable: URL
    public var arguments: [String]
}

extension ModCommand {
    /// The process to start for this command, with `modDirectory` being the copy of the mod it runs from.
    public func invocation(modDirectory: URL) -> CommandInvocation {
        switch program {
        case .exec(let file):
            CommandInvocation(executable: modDirectory.appending(path: file), arguments: args)
        case .shell(let script):
            // The word after the script becomes $0; declared args follow as $1, $2, …
            CommandInvocation(executable: URL(filePath: "/bin/sh"), arguments: ["-c", script, "toolsy"] + args)
        }
    }
}

/// Builds the environment of a command. The app and the helper both use it, so a command sees the
/// same variables whether it runs as the user or as root.
public enum CommandEnvironment {
    /// Homebrew directories are writable by the user, so they are never on root's search path.
    static let systemPath = "/usr/bin:/bin:/usr/sbin:/sbin"
    static let userPath = "/opt/homebrew/bin:/usr/local/bin:" + systemPath
    static let inheritedVariables = ["HOME", "USER", "LOGNAME", "TMPDIR", "SHELL"]
    /// The same for every command wherever it is started: Toolsy at login has no `LANG`, toolsy-mod in a
    /// terminal has the user's, and with a comma for the decimal point a mod's patches stop being JSON.
    /// A UTF-8 locale keeps tools from mangling non-ASCII text; `TOOLSY_LOCALE` says the user's language.
    static let locale = "en_US.UTF-8"
    /// The environment counts against the system's 1 MB limit for starting a program (`ARG_MAX`): one long
    /// value, such as a captured log, kept every command of its mod from starting at all. Longer values,
    /// and values past the total, reach a command only through its standard input.
    public static let maxStateVariableBytes = 32 * 1024
    public static let maxStateVariablesBytes = 256 * 1024

    public static func variables(
        modID: String,
        modDirectory: URL,
        dataDirectory: URL,
        input: CommandInput,
        privileged: Bool,
        inheriting inherited: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var variables: [String: String]
        if privileged {
            // Built by the helper, so the temporary folder is root's own, which no other user can write to.
            variables = ["HOME": "/var/root", "USER": "root", "LOGNAME": "root", "PATH": systemPath,
                         "TMPDIR": NSTemporaryDirectory(), "SHELL": "/bin/sh"]
        } else {
            variables = ["PATH": userPath]
            for name in inheritedVariables {
                variables[name] = inherited[name]
            }
        }
        variables["LANG"] = locale
        variables["TOOLSY_MOD_ID"] = modID
        variables["TOOLSY_MOD_DIR"] = modDirectory.path(percentEncoded: false)
        variables["TOOLSY_DATA_DIR"] = dataDirectory.path(percentEncoded: false)
        variables["TOOLSY_EVENT"] = input.event.rawValue
        variables["TOOLSY_COMMAND"] = input.command
        variables["TOOLSY_KEY"] = input.key
        variables["TOOLSY_VALUE"] = input.value?.text
        // For a privileged command the input was decoded from what a user-level process sent, so the locale is
        // checked here again: only a well-formed code passes.
        variables["TOOLSY_LOCALE"] = input.locale.flatMap(CommandInput.languageTag)
        // In key order, so which values fit does not change from run to run.
        var exported = 0
        for (key, value) in input.state.sorted(by: { $0.key < $1.key }) where value.isScalar {
            let name = "TOOLSY_STATE_\(key)"
            let text = value.text
            // `name=text` and the terminating NUL, as the kernel counts them.
            let size = name.utf8.count + text.utf8.count + 2
            guard text.utf8.count <= maxStateVariableBytes, exported + size <= maxStateVariablesBytes else { continue }
            exported += size
            variables[name] = text
        }
        return variables
    }
}
