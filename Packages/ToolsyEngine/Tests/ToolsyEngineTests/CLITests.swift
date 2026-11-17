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

    /// A manifest nested this deeply crashed toolsy-mod and Toolsy with a stack overflow (exit 138).
    @Test func refusesManifestsNestedTooDeeply() async throws {
        let directory = try TemporaryDirectory()
        let when = String(repeating: "(", count: 1500) + "shown" + String(repeating: ")", count: 1500)
        let deepWhen = try writeMod(manifest(#""ui": [{"type": "text", "text": "x", "when": "\#(when)"}]"#), in: directory, folder: "when")
        #expect(try await toolsyMod(["validate", deepWhen.path(percentEncoded: false)])
            == (1, "", "ui[0].when: the expression is longer than 256 tokens\n"))

        let nested = String(repeating: "[", count: 500) + String(repeating: "]", count: 500)
        let deepSettings = try writeMod(manifest(#""settings": {"x": \#(nested)}"#), in: directory, folder: "settings")
        #expect(try await toolsyMod(["validate", deepSettings.path(percentEncoded: false)])
            == (1, "", "the JSON is nested more than 64 levels deep\n"))
    }

    @Test func packsAFolderThatInstalls() async throws {
        try await withHarness { harness in
            let folder = try writeMod(manifest(#""commands": {"t": {"exec": "bin/t"}}"#), scripts: ["bin/t": #"echo '{"packed": true}'"#], in: harness.temporary)
            try harness.temporary.write("x", to: "source/.DS_Store")
            try harness.temporary.write("x", to: "source/bin/.DS_Store")
            let archive = harness.temporary.url.appending(path: "out/demo-1.toolsymod")
            try FileManager.default.createDirectory(at: archive.deletingLastPathComponent(), withIntermediateDirectories: true)

            // An author's working folder: version control and an earlier pack are not part of the mod.
            try harness.temporary.write("[core]", to: "source/.git/config")
            try harness.temporary.write("old", to: "source/demo-0.toolsymod")

            let packed = try await toolsyMod(["pack", folder.path(percentEncoded: false), "-o", archive.path(percentEncoded: false)])
            #expect(packed.status == 0 && packed.output.hasPrefix("OK demo 1.0 "))
            #expect(try await archiveEntries(archive) == ["bin/t", "mod.json"])
            let first = try Data(contentsOf: archive)
            // Packing again replaces the archive, with the same bytes although every file is newer.
            try harness.temporary.write("#!/bin/sh\n" + #"echo '{"packed": true}'"# + "\n", to: "source/bin/t", executable: true)
            try await Task.sleep(for: .seconds(1.1))
            #expect(try await toolsyMod(["pack", folder.path(percentEncoded: false), "-o", archive.path(percentEncoded: false)]).status == 0)
            #expect(try Data(contentsOf: archive) == first)

            let mod = try await harness.store.commitInstall(harness.store.prepareInstall(from: archive))
            await mod.run("t")
            #expect(mod.state["packed"] == true)
        }
    }

    /// `-o dist` with a folder named dist, or `-o .`, replaced that folder and everything in it with the archive.
    @Test func replacesNothingButAnArchive() async throws {
        let directory = try TemporaryDirectory()
        try writeMod(manifest(id: "keep-awake"), in: directory, folder: "mod")
        try directory.write("keep", to: "dist.toolsymod/inside")
        try directory.write("notes", to: "README.md")
        for (output, message) in [("dist.toolsymod", "dist.toolsymod exists and is not a file"),
                                  ("README.md", "README.md is not a .toolsymod file name"),
                                  (".", "is not a .toolsymod file name")] {
            let result = try await toolsyMod(["pack", "mod", "-o", output], in: directory.url)
            #expect(result.status == 1, "\(output)")
            #expect(result.error.contains(message), "\(output): \(result.error)")
        }
        #expect(try String(contentsOf: directory.url.appending(path: "dist.toolsymod/inside"), encoding: .utf8) == "keep")
        #expect(try String(contentsOf: directory.url.appending(path: "README.md"), encoding: .utf8) == "notes")
    }

    @Test func packsIntoTheWorkingDirectoryByDefault() async throws {
        let directory = try TemporaryDirectory()
        try writeMod(manifest(id: "keep-awake"), in: directory, folder: "mod")
        #expect(try await toolsyMod(["pack", "mod"], in: directory.url).status == 0)
        #expect(try await archiveEntries(directory.url.appending(path: "keep-awake.toolsymod")) == ["mod.json"])

        // Packing from inside the folder leaves the archive there; packing again does not take it in.
        let inside = directory.url.appending(path: "mod")
        #expect(try await toolsyMod(["pack", "."], in: inside).status == 0)
        #expect(try await toolsyMod(["pack", "."], in: inside).status == 0)
        #expect(try await archiveEntries(inside.appending(path: "keep-awake.toolsymod")) == ["mod.json"])

        let invalid = try writeMod(#"{"schema": 1}"#, in: directory, folder: "invalid")
        let result = try await toolsyMod(["pack", invalid.path(percentEncoded: false), "-o", "x.toolsymod"], in: directory.url)
        #expect(result.status == 1 && result.error.contains("missing required field"))
        #expect(!FileManager.default.fileExists(atPath: directory.url.appending(path: "x.toolsymod").path(percentEncoded: false)))
    }
}
