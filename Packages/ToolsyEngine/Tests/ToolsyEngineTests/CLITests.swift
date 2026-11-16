import Foundation
import Testing
@testable import ToolsyEngine
import ToolsyShared

private final class BundleMarker {}

/// `toolsy-mod` is built next to the test bundle.
private let tool = Bundle(for: BundleMarker.self).bundleURL.deletingLastPathComponent().appending(path: "toolsy-mod")

func toolsyMod(_ arguments: [String], in directory: URL? = nil) async throws -> (status: Int32, output: String, error: String) {
    let result = try await ProcessRunner.run(ProcessRunner.Request(
        executable: tool, arguments: arguments, environment: ProcessInfo.processInfo.environment, currentDirectory: directory
    ))
    return (result.exitCode, String(decoding: result.stdout, as: UTF8.self), String(decoding: result.stderr, as: UTF8.self))
}

/// `toolsy-mod run … --json` of a command that is expected to finish, launched again while the command
/// only waited: timed out, or, as a service, was stopped before it said anything.
///
/// macOS checks a new executable when it is first launched, about 0.4 s each and one at a time across
/// the whole system. While the suite launches the scripts it has just written, a script can wait in that
/// queue for longer than the ten seconds its command is given. The check is made once, so the next launch
/// starts at once; a script that really hangs times out every time and fails the test.
func toolsyModRun(_ arguments: [String]) async throws -> (status: Int32, output: String, error: String) {
    var result = try await toolsyMod(["run"] + arguments)
    for _ in 0..<5 {
        guard let report = try? JSONDecoder().decode(RunJSON.self, from: Data(result.output.utf8)),
              report.service ? report.lines?.isEmpty != false : report.timedOut else { break }
        result = try await toolsyMod(["run"] + arguments)
    }
    return result
}

private func archiveEntries(_ archive: URL) async throws -> [String] {
    let result = try await ProcessRunner.run(ProcessRunner.Request(
        executable: URL(filePath: "/usr/bin/zipinfo"), arguments: ["-1", archive.path(percentEncoded: false)]
    ))
    return String(decoding: result.stdout, as: UTF8.self).split(separator: "\n").map(String.init).sorted()
}

@MainActor @Suite struct CLITests {
    @Test func validatesEveryForm() async throws {
        let directory = try TemporaryDirectory()
        let folder = try writeMod(manifest(version: "2.1", #""commands": {"t": {"exec": "bin/t"}}"#), scripts: ["bin/t": "true"], in: directory)
        #expect(try await toolsyMod(["validate", folder.path(percentEncoded: false)]) == (0, "OK demo 2.1\n", ""))
        try directory.write(manifest(id: "lone"), to: "lone.json")
        #expect(try await toolsyMod(["validate", "lone.json"], in: directory.url) == (0, "OK lone 1.0\n", ""), "relative paths resolve against the working directory")

        let broken = try writeMod(manifest(#""ui": [{"type": "text", "text": "{{x|shout}}"}]"#), in: directory, folder: "broken")
        #expect(try await toolsyMod(["validate", broken.path(percentEncoded: false)]) == (1, "", "ui[0].text: unknown filter \"shout\"\n"))
        #expect(try await toolsyMod(["frobnicate"]).status == 2)
        #expect(try await toolsyMod(["pack"]).status == 2)
    }

    @Test func packsAFolderThatInstalls() async throws {
        try await withHarness { harness in
            let folder = try writeMod(manifest(#""commands": {"t": {"exec": "bin/t"}}"#), scripts: ["bin/t": #"echo '{"packed": true}'"#], in: harness.temporary)
            try harness.temporary.write("x", to: "source/.DS_Store")
            try harness.temporary.write("x", to: "source/bin/.DS_Store")
            let archive = harness.temporary.url.appending(path: "out/demo-1.toolsymod")
            try FileManager.default.createDirectory(at: archive.deletingLastPathComponent(), withIntermediateDirectories: true)

            let packed = try await toolsyMod(["pack", folder.path(percentEncoded: false), "-o", archive.path(percentEncoded: false)])
            #expect(packed.status == 0 && packed.output.hasPrefix("OK demo 1.0 "))
            #expect(try await archiveEntries(archive) == ["bin/", "bin/t", "mod.json"])
            // Packing again replaces the archive.
            #expect(try await toolsyMod(["pack", folder.path(percentEncoded: false), "-o", archive.path(percentEncoded: false)]).status == 0)

            let mod = try await harness.store.commitInstall(harness.store.prepareInstall(from: archive))
            await mod.run("t")
            #expect(mod.state["packed"] == true)
        }
    }

    @Test func packsIntoTheWorkingDirectoryByDefault() async throws {
        let directory = try TemporaryDirectory()
        try writeMod(manifest(id: "keep-awake"), in: directory, folder: "mod")
        #expect(try await toolsyMod(["pack", "mod"], in: directory.url).status == 0)
        #expect(try await archiveEntries(directory.url.appending(path: "keep-awake.toolsymod")) == ["mod.json"])

        let invalid = try writeMod(#"{"schema": 1}"#, in: directory, folder: "invalid")
        let result = try await toolsyMod(["pack", invalid.path(percentEncoded: false), "-o", "x.toolsymod"], in: directory.url)
        #expect(result.status == 1 && result.error.contains("missing required field"))
        #expect(!FileManager.default.fileExists(atPath: directory.url.appending(path: "x.toolsymod").path(percentEncoded: false)))
    }
}
