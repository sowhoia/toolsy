import Foundation
import Testing
@testable import ToolsyEngine
import ToolsyShared

/// What `validate --json` prints.
struct ValidationJSON: Decodable, Equatable {
    var ok: Bool
    var id, version, name: String?
    var commands, privilegedCommands, widgets, languages, warnings: [String]?
    var error: String?
}

@Suite struct CLIUsageTests {
    @Test func helpExplainsEveryCommand() async throws {
        let alone = try await toolsyMod([])
        #expect(alone.status == 2 && alone.output.isEmpty)
        #expect(alone.error.hasPrefix("usage: toolsy-mod <command> [<arguments>]"))
        for name in ["new", "validate", "run", "preview", "pack", "help"] {
            #expect(alone.error.contains("\n  \(name) "), "the overview lists \(name)")
            let help = try await toolsyMod(["help", name])
            #expect(help.status == 0 && help.error.isEmpty)
            #expect(help.output.hasPrefix("usage: toolsy-mod \(name)"), "\(help.output)")
        }
        #expect(try await toolsyMod(["help"]) == (0, alone.error, ""))
        #expect(try await toolsyMod(["--help"]).status == 0)

        let run = try await toolsyMod(["help", "run"]).output
        for option in ["--state", "--key", "--value", "--event", "--locale", "--data", "--for", "--as-user", "--json"] {
            #expect(run.contains("  \(option)"), "help run explains \(option)")
        }
        let new = try await toolsyMod(["help", "new"]).output
        #expect(new.hasPrefix("usage: toolsy-mod new <id> [--template basic|switch|service|widget] [--name <name>] [-o <folder>]\n"))
    }

    @Test func usageErrorsExitWithTwo() async throws {
        let cases: [([String], String)] = [
            (["frobnicate"], #"toolsy-mod: unknown command "frobnicate""#),
            (["help", "frobnicate"], #"toolsy-mod: there is no command "frobnicate""#),
            (["help", "run", "new"], #"toolsy-mod: unexpected argument "new" for help"#),
            (["validate"], "toolsy-mod: validate needs a mod: a folder, a .toolsymod file or a manifest.json"),
            (["validate", "a", "b"], #"toolsy-mod: unexpected argument "b" for validate"#),
            (["validate", "a", "--jsn"], "toolsy-mod: unknown option --jsn for validate"),
            (["validate", "a", "--json", "--json"], "toolsy-mod: --json is given twice"),
            (["validate", "a", "--json=yes"], "toolsy-mod: --json takes no value"),
            (["pack", "a", "-o"], "toolsy-mod: -o needs a value"),
            (["pack"], "toolsy-mod: pack needs a mod folder"),
            (["new", "Bad_ID"], #"toolsy-mod: "Bad_ID" is not a mod id: use 1-64 lowercase letters, digits, ".", "_" or "-", starting and ending with a letter or digit"#),
            (["new", "ok", "--template", "fancy"], #"toolsy-mod: there is no template "fancy"; choose one of basic, switch, service, widget"#),
            (["new", "ok", "--name", " "], "toolsy-mod: --name must be 1-80 characters"),
            (["run", "folder"], "toolsy-mod: run needs a mod folder and the name of one of its commands"),
            (["preview", "a", "--state", "[1]"], "toolsy-mod: --state must be a JSON object"),
        ]
        for (arguments, message) in cases {
            let result = try await toolsyMod(arguments)
            #expect(result.status == 2, "\(arguments)")
            #expect(result.output.isEmpty)
            #expect(result.error.hasPrefix(message + "\n"), "\(arguments): \(result.error)")
            // The usage of the command follows, or the overview for an unknown command.
            #expect(result.error.contains("usage: toolsy-mod"), "\(arguments)")
        }
        let wrong = try await toolsyMod(["pack", "a", "--force"])
        #expect(wrong.error == "toolsy-mod: unknown option --force for pack\nusage: toolsy-mod pack <folder> [-o <file.toolsymod>] [--sign <key>]\nRun \"toolsy-mod help pack\" for details.\n")
    }

    @Test func printsTheVersionItShipsWith() async throws {
        #expect(try await toolsyMod(["--version"]) == (0, "toolsy-mod \(ToolsyVersion.current)\n", ""))
        #expect(try await toolsyMod(["--version", "x"]).status == 2)
    }

    @Test func optionsComeAnywhereAndTakeEitherForm() async throws {
        let directory = try TemporaryDirectory()
        try writeMod(manifest(id: "keep-awake"), in: directory, folder: "mod")
        #expect(try await toolsyMod(["pack", "-o=out.toolsymod", "mod"], in: directory.url).status == 0)
        #expect(FileManager.default.fileExists(atPath: directory.url.appending(path: "out.toolsymod").path(percentEncoded: false)))
        #expect(try await toolsyMod(["validate", "--json", "mod"], in: directory.url).status == 0)
        // An empty value after "=" is that value, not the next argument.
        let empty = try await toolsyMod(["pack", "-o=", "mod"], in: directory.url)
        #expect(empty.status == 1 && empty.error.contains("is not a .toolsymod file name"), "\(empty)")
        #expect(try await toolsyMod(["validate", "mod", "--json="], in: directory.url).status == 2)
        // After "--" everything is a positional, even what looks like an option.
        try writeMod(manifest(id: "dash"), in: directory, folder: "-mod")
        #expect(try await toolsyMod(["validate", "--", "-mod"], in: directory.url) == (0, "OK dash 1.0\n", ""))
    }

    @Test func validatesAsJSON() async throws {
        let directory = try TemporaryDirectory()
        let folder = try writeMod(manifest(name: "Demo \\\"quoted\\\"", version: "2.0", #"""
            "commands": {"b": {"shell": "true", "privileged": true}, "a": {"shell": "true"}},
            "lifecycle": {"refresh": {"command": "a"}, "events": {"wake": "b"}},
            "widgets": [{"id": "two", "value": "2"}, {"id": "one", "value": "1"}],
            "localizations": {"ru": {"Demo": "Демо"}, "de": {}}
            """#), in: directory)
        let valid = try await toolsyMod(["validate", folder.path(percentEncoded: false), "--json"])
        #expect(valid.status == 0 && valid.error.isEmpty)
        #expect(try JSONDecoder().decode(ValidationJSON.self, from: Data(valid.output.utf8)) == ValidationJSON(
            ok: true, id: "demo", version: "2.0", name: "Demo \"quoted\"", commands: ["a", "b"], privilegedCommands: ["b"],
            widgets: ["two", "one"], languages: ["de", "ru"],
            warnings: [#"localizations.ru: "Demo" is not the text of any translated field, so this entry is never used"#]
        ))

        let broken = try writeMod(manifest(#""ui": [{"type": "text", "text": "{{x|shout}}"}]"#), in: directory, folder: "broken")
        let plain = try await toolsyMod(["validate", broken.path(percentEncoded: false)])
        let json = try await toolsyMod(["validate", broken.path(percentEncoded: false), "--json"])
        #expect(json.status == 1 && json.error.isEmpty)
        #expect(try JSONDecoder().decode(ValidationJSON.self, from: Data(json.output.utf8)) == ValidationJSON(ok: false, error: "ui[0].text: unknown filter \"shout\""))
        #expect(plain.error == "ui[0].text: unknown filter \"shout\"\n", "the same message as without --json")

        let missing = try await toolsyMod(["validate", directory.url.appending(path: "nothing.toolsymod").path(percentEncoded: false), "--json"])
        #expect(missing.status == 1 && missing.output.contains(#""ok" : false"#))
    }

    @Test func warningsFollowTheOKLineWithoutChangingTheStatus() async throws {
        let directory = try TemporaryDirectory()
        let folder = try writeMod(manifest(#""commands": {"go": {"shell": "bin/go"}}, "settings": {"on": 1}, "ui": [{"type": "toggle", "label": "On", "bind": "on"}]"#), in: directory)
        #expect(try await toolsyMod(["validate", folder.path(percentEncoded: false)]) == (0, "OK demo 1.0\n", """
            warning: commands.go: shell starts with "bin/go", which is not a file of the mod
            warning: ui[0]: the default of setting "on", 1, is not true or false; the toggle shows it as off

            """))
    }

    @Test func repositoryModsValidateAsBefore() async throws {
        let repository = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        // The showcase's version moves with the format; the line's shape and the silence are the contract.
        let showcase = try ModManifest.load(from: Data(contentsOf: repository.appending(path: "Mods/showcase/mod.json")))
        #expect(try await toolsyMod(["validate", "Mods/showcase"], in: repository) == (0, "OK showcase \(showcase.version)\n", ""))
        // A lone manifest has no files, so the program its command names is missing; that message is part of the contract.
        #expect(try await toolsyMod(["validate", "Mods/vpn-protector/mod.json"], in: repository)
            == (1, "", "commands.check: exec file \"bin/vpn-protector\" is not part of the mod\n"))
    }
}
