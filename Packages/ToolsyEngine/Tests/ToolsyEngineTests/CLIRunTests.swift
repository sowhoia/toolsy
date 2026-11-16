import Foundation
import Testing
@testable import ToolsyEngine
import ToolsyShared

/// What `run --json` prints.
struct RunJSON: Decodable {
    struct Output: Decodable, Equatable {
        struct Notification: Decodable, Equatable {
            var title, body: String
        }

        var kind: String
        var patch: ModState?
        var text: String?
        var value: JSONValue?
        var reason: String?
        var hostKeys: [String]
        var notification: Notification?
    }

    var ok: Bool
    var mod, command, program, event: String
    var locale: String?
    var key: String?
    var value: JSONValue?
    var stdin: CommandInput?
    var dataDirectory: String
    var dataDirectoryRemoved: Bool
    var exitStatus: Int32?
    var timedOut: Bool
    var timeout, seconds: Double
    var service: Bool
    var output: Output?
    var lines: [Output]?
    var error: String?
    var notes: [String]
    var stderr: String
}

@Suite struct CLIRunTests {
    /// `run --json`; `finishing` commands are launched again while they only waited (`toolsyModRun`).
    private func run(_ folder: URL, _ arguments: [String], finishing: Bool = false) async throws -> (status: Int32, report: RunJSON) {
        let all = [folder.path(percentEncoded: false)] + arguments + ["--json"]
        let result = try await (finishing ? toolsyModRun(all) : toolsyMod(["run"] + all))
        #expect(result.error.isEmpty, "\(result.error)")
        return (result.status, try JSONDecoder().decode(RunJSON.self, from: Data(result.output.utf8)))
    }

    @Test func runsACommandAsToolsyDoes() async throws {
        let directory = try TemporaryDirectory()
        let folder = try writeMod(manifest(#"""
            "settings": {"host": "a.example", "level2": 3},
            "commands": {
              "echo": {"exec": "bin/echo", "args": ["one", "two words"], "stdin": true, "timeout": 9},
              "where": {"shell": "printf '{\"cwd\": \"%s\", \"data\": \"%s\", \"dir\": \"%s\", \"id\": \"%s\", \"path\": \"%s\", \"host\": \"%s\", \"on\": \"%s\", \"argv\": \"%s\"}' \"$PWD\" \"$TOOLSY_DATA_DIR\" \"$TOOLSY_MOD_DIR\" \"$TOOLSY_MOD_ID\" \"$PATH\" \"$TOOLSY_STATE_host\" \"$TOOLSY_STATE_enabled\" \"$1\"", "args": ["first"]}
            },
            "ui": [{"type": "input", "bind": "host", "command": "echo"}, {"type": "list", "bind": "rows", "command": "echo"}, {"type": "button", "label": "W", "command": "where"}]
            """#), scripts: ["bin/echo": #"printf '{"argv": "%s|%s", "event": "%s", "key": "%s", "value": "%s", "locale": "%s", "input": %s}' "$1" "$2" "$TOOLSY_EVENT" "$TOOLSY_KEY" "$TOOLSY_VALUE" "$TOOLSY_LOCALE" "$(cat)""#], in: directory)

        let (status, report) = try await run(folder, ["echo", "--key", "host", "--value", #""b.example""#, "--locale", "pt-BR",
                                                       "--state", #"{"enabled": true, "level2": null, "extra": [1]}"#, "--event", "wake"],
                                             finishing: true)
        #expect(status == 0 && report.ok && report.exitStatus == 0 && !report.timedOut && report.timeout == 9)
        #expect(report.mod == "demo" && report.command == "echo" && report.program == "exec bin/echo one two words")
        #expect(report.event == "wake" && report.locale == "pt-br" && report.key == "host" && report.value == "b.example")
        let state: ModState = ["host": "b.example", "enabled": true, "extra": [1]]
        let input = CommandInput(event: .wake, command: "echo", key: "host", value: "b.example", state: state, locale: "pt-BR")
        #expect(report.stdin == input, "an input binds host, so the value is in the state; null removed level2")
        let patch = try #require(report.output?.patch)
        #expect(patch["argv"] == "one|two words" && patch["event"] == "wake" && patch["key"] == "host" && patch["value"] == "b.example")
        #expect(patch["locale"] == "pt-br")
        #expect(patch["input"].flatMap { try? JSONDecoder().decode(CommandInput.self, from: JSONEncoder().encode($0)) } == input)
        #expect(report.notes == [#"an input binds "host", so its value was stored in the state first, as the control does"#])
        #expect(report.dataDirectoryRemoved && !FileManager.default.fileExists(atPath: report.dataDirectory))

        // A list row's click sends its key and value but stores nothing; the default event is "command".
        let (_, row) = try await run(folder, ["echo", "--key", "rows", "--value", #""en0""#, "--locale", "en"])
        #expect(row.stdin?.state == ["host": "a.example", "level2": 3, "enabled": false] && row.event == "command" && row.notes.isEmpty)

        let data = directory.url.appending(path: "kept", directoryHint: .isDirectory)
        let (_, environment) = try await run(folder, ["where", "--data", data.path(percentEncoded: false), "--locale", "en"])
        let modDirectory = folder.path(percentEncoded: false)
        // The shell reports the working directory with symbolic links resolved (/var is /private/var).
        let physical = try #require(realpath(modDirectory, nil))
        defer { free(physical) }
        #expect(environment.output?.patch == [
            "cwd": .string(String(cString: physical)), "data": .string(data.path(percentEncoded: false)), "dir": .string(modDirectory),
            "id": "demo", "path": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin", "host": "a.example", "on": "false", "argv": "first",
        ])
        #expect(environment.stdin == nil && environment.program.hasPrefix("shell \"printf ") && environment.program.hasSuffix(" first"))
        #expect(!environment.dataDirectoryRemoved && FileManager.default.fileExists(atPath: data.path(percentEncoded: false)))
    }

    @Test func reportsWhatToolsyMakesOfTheOutput() async throws {
        let directory = try TemporaryDirectory()
        let folder = try writeMod(manifest(#"""
            "settings": {"limit": 1},
            "commands": {
              "text": {"shell": "echo hello"}, "array": {"shell": "echo '[1, 2]'"}, "nothing": {"shell": "true"},
              "ip": {"shell": "printf '  10.0.0.2\\n'", "capture": "ip"},
              "mixed": {"shell": "echo '{\"status\": 7, \"level\": \"green\", \"enabled\": \"yes\", \"bad-key\": 1, \"notify\": 5, \"limit\": 2, \"error\": \"Oops\"}'"},
              "notify": {"shell": "echo '{\"notify\": \"Saved\", \"status\": \"Done\", \"level\": \"ok\", \"error\": null}'"}
            },
            "ui": [{"type": "button", "label": "B", "command": "text"}, {"type": "button", "label": "B", "command": "array"},
                   {"type": "button", "label": "B", "command": "nothing"}, {"type": "button", "label": "B", "command": "ip"},
                   {"type": "button", "label": "B", "command": "mixed"}, {"type": "button", "label": "B", "command": "notify"}],
            "localizations": {"ru": {"Demo": "Демо"}}
            """#), in: directory)

        let text = try await run(folder, ["text", "--locale", "en"]).report
        #expect(text.ok && text.output?.kind == "notJSON" && text.output?.text == "hello\n" && text.output?.reason?.isEmpty == false)
        #expect(text.notes == [#"the output is not JSON, so Toolsy ignores it; print one JSON object, or set "capture" to keep text"#])
        let array = try await run(folder, ["array", "--locale", "en"]).report
        #expect(array.output == RunJSON.Output(kind: "notAnObject", value: [1, 2], hostKeys: []))
        #expect(try await run(folder, ["nothing", "--locale", "en"]).report.output == RunJSON.Output(kind: "empty", hostKeys: []))
        #expect(try await run(folder, ["ip", "--locale", "en"]).report.output == RunJSON.Output(kind: "capture", patch: ["ip": "10.0.0.2"], hostKeys: []))

        let mixed = try await run(folder, ["mixed", "--locale", "en"]).report
        #expect(mixed.output?.hostKeys == ["error", "level", "status"], "an enabled that is not a boolean is ignored")
        #expect(mixed.notes == [
            #""bad-key" is not a valid state key ([A-Za-z_][A-Za-z0-9_]*, up to 64), so Toolsy ignores it"#,
            #"enabled must be true or false, so Toolsy ignores "yes""#,
            #"level is one of "ok", "warn", "error" and "off"; "green" colours nothing"#,
            #""limit" is a setting: Toolsy saves its new value"#,
            #"notify must be text or an object with "title" and "body", so Toolsy ignores 5"#,
            "status is shown only when it is text; 7 shows no status",
        ])

        // Notifications carry the mod's name in the user's language.
        let notify = try await run(folder, ["notify", "--locale", "ru"]).report
        #expect(notify.output?.notification == RunJSON.Output.Notification(title: "Демо", body: "Saved"))
        #expect(notify.output?.hostKeys == ["error", "level", "status"] && notify.notes.isEmpty)
        let plain = try await toolsyMod(["run", folder.path(percentEncoded: false), "notify", "--locale", "en"])
        #expect(plain.status == 0 && plain.error.isEmpty)
        #expect(plain.output.contains("""
            toolsy:  error = null: clears the mod's error
            toolsy:  level = "ok": the colour of that line
            toolsy:  status = "Done": the line under the mod's name
            notify:  title "Demo", body "Saved"
            stderr:  (empty)
            """), "\(plain.output)")
    }

    @Test func failuresShowTheErrorToolsyWouldShow() async throws {
        let directory = try TemporaryDirectory()
        let folder = try writeMod(manifest(#"""
            "commands": {
              "stderr": {"shell": "echo '{\"status\": \"half\", \"notify\": \"x\"}'; echo 'first' >&2; echo 'Disk is full' >&2; exit 3"},
              "reported": {"shell": "echo '{\"error\": \"No network\"}'; echo ignored >&2; exit 1"},
              "silent": {"shell": "exit 4"},
              "slow": {"shell": "sleep 10", "timeout": 1},
              "missing": {"exec": "bin/gone"}
            },
            "ui": [{"type": "button", "label": "B", "command": "stderr"}, {"type": "button", "label": "B", "command": "reported"},
                   {"type": "button", "label": "B", "command": "silent"}, {"type": "button", "label": "B", "command": "slow"},
                   {"type": "button", "label": "B", "command": "missing"}]
            """#), scripts: ["bin/gone": "true"], in: directory)
        let discarded = "the command failed, so Toolsy discards its output (a patch and its notify included) and keeps the state as it was"

        let (status, failed) = try await run(folder, ["stderr", "--locale", "en"])
        #expect(status == 1 && !failed.ok && failed.exitStatus == 3 && failed.error == "Disk is full")
        #expect(failed.stderr == "first\nDisk is full\n" && failed.notes == [discarded])
        #expect(failed.output == RunJSON.Output(kind: "patch", patch: ["status": "half", "notify": "x"], hostKeys: []), "shown, not applied")
        #expect(try await run(folder, ["reported", "--locale", "en"]).report.error == "No network")
        #expect(try await run(folder, ["silent", "--locale", "en"]).report.error == "\"silent\" failed: exit status 4.")

        let (slowStatus, slow) = try await run(folder, ["slow", "--locale", "en"])
        #expect(slowStatus == 1 && slow.timedOut && slow.error == "\"slow\" failed: timed out after 1 s.")
        let text = try await toolsyMod(["run", folder.path(percentEncoded: false), "stderr", "--locale", "en"])
        #expect(text.status == 1 && text.output.contains("""
            result:  FAILED: exit status 3 after
            """) && text.output.contains("""
            error:   Toolsy shows "Disk is full"
            """) && text.output.contains("""
            stderr:  first
                     Disk is full
            """), "\(text.output)")

        // A program the system cannot start: executable, but neither a binary nor a script with "#!".
        try directory.write("not a program", to: "source/bin/gone", executable: true)
        let (startStatus, unstartable) = try await run(folder, ["missing", "--locale", "en"])
        #expect(startStatus == 1 && !unstartable.ok && unstartable.exitStatus == nil && unstartable.output == nil)
        #expect(unstartable.error?.hasPrefix("Cannot start ") == true, "\(unstartable.error ?? "")")

        try FileManager.default.removeItem(at: folder.appending(path: "bin/gone"))
        let invalid = try await toolsyMod(["run", folder.path(percentEncoded: false), "silent"])
        #expect(invalid == (1, "", "commands.missing: exec file \"bin/gone\" is not part of the mod\n"), "run validates the mod first")
    }

    @Test func runsTheServiceForAWhile() async throws {
        let directory = try TemporaryDirectory()
        let folder = try writeMod(manifest(#"""
            "commands": {"watch": {"shell": "echo '{\"n\": 1}'; echo; echo nope; echo '{\"notify\": \"Up\"}'; exec sleep 30"}},
            "lifecycle": {"service": "watch"}
            """#), in: directory)
        let (status, report) = try await run(folder, ["watch", "--for", "1.5", "--locale", "en"])
        #expect(status == 0 && report.ok && report.service && report.timedOut && report.event == "service" && report.timeout == 1.5)
        #expect(report.output == nil)
        #expect(report.lines?.map(\.kind) == ["patch", "notJSON", "patch"])
        #expect(report.lines?.last?.notification == RunJSON.Output.Notification(title: "Demo", body: "Up"))
        #expect(report.notes == [#"line 2: the output is not JSON, so Toolsy ignores it; print one JSON object, or set "capture" to keep text"#])

        let text = try await toolsyMod(["run", folder.path(percentEncoded: false), "watch", "--for", "1", "--locale", "en"])
        #expect(text.output.contains("""
            output:  3 lines, each applied at once:
                     line 1: a patch {"n":1}
            """) && text.output.contains("notify:  line 3: title \"Demo\", body \"Up\""), "\(text.output)")

        // A service that crashes, and one that ends by itself.
        let other = try writeMod(manifest(id: "other", #""commands": {"s": {"shell": "echo 'Port busy' >&2; exit 5"}}, "lifecycle": {"service": "s"}"#),
                                 in: directory, folder: "other")
        let (crashStatus, crash) = try await run(other, ["s", "--locale", "en"])
        #expect(crashStatus == 1 && !crash.ok && crash.exitStatus == 5 && crash.error == "Port busy" && !crash.timedOut)
        let quiet = try writeMod(manifest(id: "quiet", #""commands": {"s": {"shell": "true"}}, "lifecycle": {"service": "s"}"#),
                                 in: directory, folder: "quiet")
        let (endStatus, ended) = try await run(quiet, ["s", "--locale", "en"])
        #expect(endStatus == 0 && ended.ok && ended.exitStatus == 0 && ended.lines == [])
        #expect(ended.notes == ["the service ended with exit status 0: Toolsy switches the mod off, as if the user had (running disable)"])
    }

    @Test func privilegedCommandsNeverRunAsRoot() async throws {
        let directory = try TemporaryDirectory()
        let folder = try writeMod(manifest(#"""
            "commands": {"apply": {"shell": "printf '{\"path\": \"%s\", \"user\": \"%s\", \"uid\": %s}' \"$PATH\" \"$USER\" \"$(id -u)\"", "privileged": true},
                         "plain": {"shell": "true"}},
            "ui": [{"type": "button", "label": "A", "command": "apply"}, {"type": "button", "label": "P", "command": "plain"}]
            """#), in: directory)
        let refused = try await toolsyMod(["run", folder.path(percentEncoded: false), "apply"])
        #expect(refused.status == 2 && refused.output.isEmpty)
        #expect(refused.error.hasPrefix(#"toolsy-mod: "apply" is privileged: Toolsy runs it as root through its helper, and toolsy-mod never does. Add --as-user"#))

        let (status, report) = try await run(folder, ["apply", "--as-user", "--locale", "en"])
        #expect(status == 0)
        #expect(report.output?.patch == ["path": "/usr/bin:/bin:/usr/sbin:/sbin", "user": "root", "uid": .number(Double(getuid()))],
                "root's environment, the user's identity")
        #expect(report.notes.first?.hasPrefix(#""apply" is privileged: it ran as \#(NSUserName()), not root"#) == true)
        #expect(try await toolsyMod(["run", folder.path(percentEncoded: false), "plain", "--as-user"]).status == 2)
    }

    @Test func misuseExitsWithTwo() async throws {
        let directory = try TemporaryDirectory()
        let folder = try writeMod(manifest(#""commands": {"go": {"shell": "true"}}, "ui": [{"type": "button", "label": "G", "command": "go"}]"#), in: directory)
        let path = folder.path(percentEncoded: false)
        try directory.write(manifest(id: "lone"), to: "lone.json")
        let cases: [([String], String)] = [
            ([path, "stop"], #"demo has no command "stop"; its commands: go"#),
            ([path, "go", "--for", "2"], #"--for applies to the service only; "go" runs to its end or its timeout"#),
            ([path, "go", "--for", "0"], #"--for: "0" is not a number of seconds between 0 and 3600"#),
            ([path, "go", "--key", "k"], "--key needs --value: a control always sends its value with its key"),
            ([path, "go", "--key", "bad key", "--value", "1"], #"--key: "bad key" is not a valid state key"#),
            ([path, "go", "--value", "hello"], "--value: not JSON ("),
            ([path, "go", "--event", "boot"], #"--event: "boot" is not one of enable, disable, uninstall, refresh, service, command, launch, wake, network, power"#),
            ([path, "go", "--locale", "русский"], #"--locale: "русский" is not a BCP 47 language code such as ru or en-us"#),
            ([path, "go", "--state", "[]"], "--state must be a JSON object"),
            ([path, "go", "--state", #"{"notify": "x"}"#], "--state: notify is never part of the state"),
            ([path, "go", "--state", #"{"enabled": 1}"#], "--state: enabled must be true or false"),
            ([path, "go", "--state", #"{"a-b": 1}"#], #"--state: "a-b" is not a valid state key"#),
            ([directory.url.appending(path: "lone.json").path(percentEncoded: false), "go"], "is not a folder: run takes an unpacked mod"),
        ]
        for (arguments, message) in cases {
            let result = try await toolsyMod(["run"] + arguments)
            #expect(result.status == 2 && result.output.isEmpty, "\(arguments)")
            #expect(result.error.hasPrefix("toolsy-mod: ") && result.error.contains(message), "\(arguments): \(result.error)")
        }
    }
}

extension RunJSON.Output {
    init(kind: String, patch: ModState? = nil, value: JSONValue? = nil, hostKeys: [String], notification: Notification? = nil) {
        self.init(kind: kind, patch: patch, text: nil, value: value, reason: nil, hostKeys: hostKeys, notification: notification)
    }
}
