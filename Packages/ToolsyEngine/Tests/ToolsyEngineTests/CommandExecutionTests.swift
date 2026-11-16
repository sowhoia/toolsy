import Foundation
import Testing
@testable import ToolsyEngine
import ToolsyShared

@Suite struct CommandExecutionTests {
    @Test func classifiesOutputAsToolsyReadsIt() {
        #expect(CommandOutput(Data()) == .empty)
        #expect(CommandOutput(Data(" \n\t\r\n".utf8)) == .empty)
        #expect(CommandOutput(Data(#"{"a": 1, "b": null}"#.utf8)) == .patch(["a": 1, "b": nil]))
        #expect(CommandOutput(Data("[1, 2]\n".utf8)) == .notAnObject([1, 2]))
        #expect(CommandOutput(Data("42".utf8)) == .notAnObject(42))
        #expect(CommandOutput(Data(#"{"a": 1}"#.utf8)).patch == ["a": 1])
        #expect(CommandOutput(Data("42".utf8)).patch == nil)

        for text in ["hello", #"{"a": 1} trailing"#, "{'a': 1}", #"{"a": 1}{"b": 2}"#] {
            guard case .notJSON(let reason) = CommandOutput(Data(text.utf8)) else {
                Issue.record("\(text) was read as JSON")
                continue
            }
            #expect(!reason.isEmpty, "\(text)")
        }
        // The parser's own words say where the problem is.
        guard case .notJSON(let reason) = CommandOutput(Data("{\"a\": 1,\n x}".utf8)) else {
            Issue.record("not read as broken JSON")
            return
        }
        #expect(reason.contains("line 2"), "\(reason)")
    }

    @Test func failureMessagePrefersTheReportedErrorThenStandardError() {
        let reported = CommandResult(exitCode: 2, stdout: Data(#"{"error": "No network"}"#.utf8), stderr: Data("ignored\n".utf8))
        #expect(reported.failureMessage(command: "go", timeout: 30) == "No network")
        let blankReport = CommandResult(exitCode: 2, stdout: Data(#"{"error": ""}"#.utf8), stderr: Data("first\n  second  \n\n".utf8))
        #expect(blankReport.failureMessage(command: "go", timeout: 30) == "second")
        #expect(CommandResult(exitCode: 3).failureMessage(command: "go", timeout: 30) == "\"go\" failed: exit status 3.")
        let timedOut = CommandResult(exitCode: 143, timedOut: true)
        #expect(timedOut.failureMessage(command: "go", timeout: 1.5) == "\"go\" failed: timed out after 1.5 s.")
        #expect(timedOut.failureDetail(timeout: 30) == "timed out after 30 s")
        #expect(CommandResult(exitCode: 1).failureDetail(timeout: 30) == "exit status 1")

        #expect(CommandResult(exitCode: 1, stdout: Data(#"{"error": "x"}"#.utf8), stderr: Data("gone\n".utf8)).serviceFailureMessage == "gone")
        #expect(CommandResult(exitCode: 9).serviceFailureMessage == "The service stopped unexpectedly (exit status 9).")
    }

    @Test func requestIsTheOneToolsyStarts() async throws {
        let directory = try TemporaryDirectory()
        let folder = try writeMod(manifest(#""commands": {"t": {"exec": "bin/t", "args": ["a"], "stdin": true, "timeout": 7}, "s": {"shell": "true"}}"#),
                                  scripts: ["bin/t": "cat"], in: directory)
        let mod = try ModManifest.load(from: Data(contentsOf: folder.appending(path: "mod.json")))
        let data = directory.url.appending(path: "data/demo", directoryHint: .isDirectory)
        let input = CommandInput(event: .command, command: "t", key: "k", value: 1, state: ["k": 1, "on": true], locale: "ru")

        let request = try #require(mod.commands["t"]).request(modID: "demo", modDirectory: folder, dataDirectory: data, input: input)
        #expect(FileManager.default.fileExists(atPath: data.path(percentEncoded: false)), "the data directory is created first")
        #expect(request.executable == folder.appending(path: "bin/t"))
        #expect(request.arguments == ["a"])
        #expect(request.currentDirectory == folder)
        #expect(request.timeout == 7)
        #expect(try JSONDecoder().decode(CommandInput.self, from: #require(request.stdin)) == input)
        #expect(request.environment == CommandEnvironment.variables(modID: "demo", modDirectory: folder, dataDirectory: data, input: input, privileged: false))
        #expect(request.environment["PATH"]?.hasPrefix("/opt/homebrew/bin:") == true)

        let shell = try #require(mod.commands["s"]).request(modID: "demo", modDirectory: folder, dataDirectory: data, input: input, privileged: true)
        #expect(shell.stdin == nil)
        #expect(shell.timeout == ModCommand.defaultTimeout)
        #expect(shell.environment["PATH"] == "/usr/bin:/bin:/usr/sbin:/sbin", "root's environment, as the helper builds it")

        let result = try await ProcessRunner.run(request)
        #expect(result.succeeded && CommandOutput(result.stdout).patch?["command"] == "t")
    }

    @Test func notificationsAreReadAsToolsyShowsThem() {
        #expect(ModNotification("Done", modID: "m", modName: "Mod")?.title == "Mod")
        #expect(ModNotification(["title": "T", "body": "B"], modID: "m", modName: "Mod").map { [$0.title, $0.body] } == ["T", "B"])
        #expect(ModNotification("  ", modID: "m", modName: "Mod") == nil)
        #expect(ModNotification(7, modID: "m", modName: "Mod") == nil)
    }
}
