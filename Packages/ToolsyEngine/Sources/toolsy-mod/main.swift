import Foundation
import ToolsyEngine
import ToolsyShared

func absolute(_ argument: String) -> URL {
    URL(filePath: argument, relativeTo: .currentDirectory()).absoluteURL.standardizedFileURL
}

func printError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

/// Pretty-printed with sorted keys, so the output is stable from run to run.
func printJSON(_ value: some Encodable) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    print(String(decoding: try encoder.encode(value), as: UTF8.self))
}

/// Runs the command named by the first argument and returns the exit status.
func perform(_ arguments: [String]) async throws -> Int32 {
    guard let command = arguments.first else {
        printError(Usage.overview)
        return 2
    }
    let rest = arguments.dropFirst()
    switch command {
    case "new":
        return try NewCommand(Arguments(rest, command: command, options: ["--template", "--name", "-o"])).run()
    case "validate":
        let arguments = try Arguments(rest, command: command, switches: ["--json"])
        let package = try arguments.positionals(1...1, "a mod: a folder, a .toolsymod file or a manifest.json")[0]
        return try await validate(absolute(package), json: arguments.has("--json"))
    case "run":
        let arguments = try Arguments(rest, command: command, options: RunCommand.options, switches: ["--as-user", "--json"])
        return try await RunCommand(arguments).run()
    case "preview":
        let arguments = try Arguments(rest, command: command, options: ["--state", "--language"])
        return try await PreviewCommand(arguments).run()
    case "pack":
        let arguments = try Arguments(rest, command: command, options: ["-o"])
        let folder = absolute(try arguments.positionals(1...1, "a mod folder")[0])
        let archive = if let output = arguments.value("-o") {
            absolute(output)
        } else {
            absolute("\(try await ModPackage.validate(folder).id).toolsymod")
        }
        let manifest = try await ModPackage.pack(folder, to: archive)
        print("OK \(manifest.id) \(manifest.version) \(archive.path(percentEncoded: false))")
        return 0
    case "--version":
        _ = try Arguments(rest, command: command).positionals(0...0, "")
        print("toolsy-mod \(ToolsyVersion.current)")
        return 0
    case "help", "--help", "-h":
        let topic = try Arguments(rest, command: "help").positionals(0...1, "")
        guard let name = topic.first else {
            print(Usage.overview)
            return 0
        }
        guard Usage.commands.contains(name) else {
            throw UsageError(message: "there is no command \"\(name)\"", command: nil)
        }
        print(Usage.text(of: name))
        return 0
    default:
        throw UsageError(message: "unknown command \"\(command)\"", command: nil)
    }
}

/// `validate`: "OK <id> <version>" and warnings on standard error, or one JSON object.
func validate(_ package: URL, json: Bool) async throws -> Int32 {
    struct Valid: Encodable {
        let ok = true
        let id, version, name: String
        let commands, privilegedCommands, widgets, languages, warnings: [String]
    }
    struct Invalid: Encodable {
        let ok = false
        let error: String
    }
    let manifest: ModManifest, warnings: [String]
    do {
        (manifest, warnings) = try await ModPackage.inspect(package)
    } catch where json {
        try printJSON(Invalid(error: error.localizedDescription))
        return 1
    }
    if json {
        try printJSON(Valid(
            id: manifest.id, version: manifest.version, name: manifest.name,
            commands: manifest.commands.keys.sorted(),
            privilegedCommands: manifest.commands.filter(\.value.privileged).keys.sorted(),
            widgets: manifest.widgets.map(\.id),
            languages: manifest.localizations.keys.sorted(),
            warnings: warnings
        ))
    } else {
        print("OK \(manifest.id) \(manifest.version)")
        warnings.forEach { printError("warning: \($0)") }
    }
    return 0
}

do {
    exit(try await perform(Array(CommandLine.arguments.dropFirst())))
} catch let error as UsageError {
    printError("toolsy-mod: \(error.message)")
    printError(error.command.map { "\(Usage.synopsis(of: $0))\nRun \"toolsy-mod help \($0)\" for details." } ?? Usage.overview)
    exit(2)
} catch {
    printError(error.localizedDescription)
    exit(1)
}
