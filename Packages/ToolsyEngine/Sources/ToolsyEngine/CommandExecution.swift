import Foundation
import ToolsyShared

// How Toolsy starts a command and reads what it produced. `Mod` runs commands with these, and
// `toolsy-mod run` uses the same code, so a mod author sees exactly what Toolsy would do.

extension ModCommand {
    /// The process Toolsy starts for this command as the user: the mod's folder as working directory,
    /// `CommandEnvironment` variables (root's when `privileged`, as the helper builds them), the input on
    /// standard input when the command asks for it, and its timeout. Creates `dataDirectory` first.
    public func request(modID: String, modDirectory: URL, dataDirectory: URL, input: CommandInput,
                        privileged: Bool = false) throws -> ProcessRunner.Request {
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        let invocation = invocation(modDirectory: modDirectory)
        return ProcessRunner.Request(
            executable: invocation.executable,
            arguments: invocation.arguments,
            environment: CommandEnvironment.variables(
                modID: modID, modDirectory: modDirectory, dataDirectory: dataDirectory, input: input, privileged: privileged
            ),
            currentDirectory: modDirectory,
            stdin: stdin ? try JSONEncoder().encode(input) : nil,
            timeout: timeout
        )
    }
}

/// What a command's standard output (or one line of a service) is to Toolsy (MOD_FORMAT.md, "Output").
public enum CommandOutput: Sendable, Equatable {
    /// Nothing but whitespace: changes nothing.
    case empty
    /// A JSON object, merged into the mod's state.
    case patch(ModState)
    /// Valid JSON of another kind; ignored.
    case notAnObject(JSONValue)
    /// Not JSON at all; ignored. `reason` is the parser's explanation.
    case notJSON(reason: String)

    public init(_ output: Data) {
        guard !output.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) else {
            self = .empty
            return
        }
        do {
            let value = try JSONDecoder().decode(JSONValue.self, from: output)
            self = value.objectValue.map(Self.patch) ?? .notAnObject(value)
        } catch DecodingError.dataCorrupted(let context) {
            // The decoder's own sentence is generic; the parser's says where the problem is.
            let underlying = (context.underlyingError as? NSError)?.userInfo[NSDebugDescriptionErrorKey] as? String
            self = .notJSON(reason: underlying ?? context.debugDescription)
        } catch {
            self = .notJSON(reason: error.localizedDescription)
        }
    }

    /// The patch, or nil for every output Toolsy ignores.
    public var patch: ModState? {
        if case .patch(let patch) = self { patch } else { nil }
    }
}

extension CommandResult {
    /// Why a run failed, in a few words: "timed out after 30 s" or "exit status 3".
    public func failureDetail(timeout: Double) -> String {
        timedOut ? "timed out after \(JSONValue.number(timeout).text) s" : "exit status \(exitCode)"
    }

    /// The `error` Toolsy shows when this run failed (MOD_FORMAT.md, "Output"): the `error` string of a JSON
    /// object on standard output, else the last non-empty line of standard error, else a generic message.
    public func failureMessage(command name: String, timeout: Double) -> String {
        let reported = CommandOutput(stdout).patch?[ReservedStateKey.error]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        return reported ?? lastNonEmptyLine(stderr) ?? "\"\(name)\" failed: \(failureDetail(timeout: timeout))."
    }

    /// The `error` Toolsy shows when the service ends with this result and a status other than 0: the last
    /// non-empty line of standard error, else a generic message. Its standard output was applied line by line.
    public var serviceFailureMessage: String {
        lastNonEmptyLine(stderr) ?? "The service stopped unexpectedly (exit status \(exitCode))."
    }
}
