import Foundation
import Testing
@testable import ToolsyShared

private let manifestData = Data(#"{"schema": 1, "id": "demo", "name": "Demo", "version": "1.0"}"#.utf8)

/// A scratch directory removed when the test ends.
final class TemporaryDirectory {
    let url: URL

    init() throws {
        url = URL.temporaryDirectory.appending(path: "toolsy-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    @discardableResult
    func write(_ contents: String, to relativePath: String, executable: Bool = false) throws -> URL {
        let file = url.appending(path: relativePath)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: file)
        if executable {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path(percentEncoded: false))
        }
        return file
    }
}

@Suite struct ModPayloadTests {
    @Test func readsDirectory() throws {
        let directory = try TemporaryDirectory()
        try directory.write(String(decoding: manifestData, as: UTF8.self), to: "mod.json")
        try directory.write("#!/bin/sh\necho hi\n", to: "bin/run.sh", executable: true)
        try directory.write("notes", to: "docs/readme.txt")
        try directory.write("junk", to: "docs/.DS_Store")

        let payload = try ModPayload(directory: directory.url)
        #expect(Set(payload.files.keys) == ["mod.json", "bin/run.sh", "docs/readme.txt"])
        #expect(payload.executables == ["bin/run.sh"])
        #expect(payload.manifestData == manifestData)
    }

    @Test func refusesSymbolicLinks() throws {
        let directory = try TemporaryDirectory()
        try directory.write(String(decoding: manifestData, as: UTF8.self), to: "mod.json")
        try FileManager.default.createSymbolicLink(
            at: directory.url.appending(path: "passwd"), withDestinationURL: URL(filePath: "/etc/passwd")
        )
        #expect(throws: ModPayloadError.self) { try ModPayload(directory: directory.url) }
    }

    @Test func requiresManifest() throws {
        let directory = try TemporaryDirectory()
        try directory.write("x", to: "other.txt")
        #expect(throws: ModPayloadError("mod.json is missing")) { try ModPayload(directory: directory.url) }
    }

    @Test func digestCoversPathsContentsAndExecutableBits() throws {
        let base = try ModPayload(files: ["mod.json": manifestData, "a": Data("1".utf8)], executables: [])
        let same = try ModPayload(files: ["a": Data("1".utf8), "mod.json": manifestData], executables: [])
        let otherContent = try ModPayload(files: ["mod.json": manifestData, "a": Data("2".utf8)], executables: [])
        let otherPath = try ModPayload(files: ["mod.json": manifestData, "b": Data("1".utf8)], executables: [])
        let otherMode = try ModPayload(files: ["mod.json": manifestData, "a": Data("1".utf8)], executables: ["a"])
        #expect(base.digest.count == 64)
        #expect(base.digest == same.digest)
        #expect(Set([base, otherContent, otherPath, otherMode].map(\.digest)).count == 4)
    }

    @Test func digestMatchesBetweenDiskAndMemory() throws {
        let directory = try TemporaryDirectory()
        try directory.write(String(decoding: manifestData, as: UTF8.self), to: "mod.json")
        try directory.write("tool", to: "bin/tool", executable: true)
        let fromDisk = try ModPayload(directory: directory.url)
        let inMemory = try ModPayload(files: ["mod.json": manifestData, "bin/tool": Data("tool".utf8)], executables: ["bin/tool"])
        #expect(fromDisk.digest == inMemory.digest)
    }

    @Test func refusesUnsafeOrAmbiguousPaths() {
        for path in ["../x", "/abs", "a//b", "a/./b", "a/../b", "", "a\\b", "a\u{0}b", "new\nline"] {
            #expect(!ModPayload.isSafeRelativePath(path), "\(path.debugDescription) must be unsafe")
            #expect(throws: ModPayloadError.self) {
                try ModPayload(files: ["mod.json": manifestData, path: Data()], executables: [])
            }
        }
        #expect(ModPayload.isSafeRelativePath("bin/tool"))
        #expect(ModPayload.isSafeRelativePath("файл с пробелом.txt"))
        #expect(throws: ModPayloadError.self) {
            try ModPayload(files: ["mod.json": manifestData, "Tool": Data(), "tool": Data()], executables: [])
        }
        #expect(throws: ModPayloadError.self) {
            try ModPayload(files: ["mod.json": manifestData, "bin": Data(), "bin/tool": Data()], executables: [])
        }
        #expect(throws: ModPayloadError.self) {
            try ModPayload(files: ["mod.json": manifestData], executables: ["ghost"])
        }
    }
}

@Suite struct CommandContractTests {
    private let input = CommandInput(
        event: .command, command: "apply", key: "level", value: 7,
        state: ["host": "1.1.1.1", "level": 7, "on": true, "rows": [1, 2], "nothing": nil]
    )

    @Test func exportsStateAndMetadata() {
        let variables = CommandEnvironment.variables(
            modID: "demo", modDirectory: URL(filePath: "/mods/demo"), dataDirectory: URL(filePath: "/data/demo"),
            input: input, privileged: false
        )
        #expect(variables["TOOLSY_MOD_ID"] == "demo")
        #expect(variables["TOOLSY_MOD_DIR"] == "/mods/demo")
        #expect(variables["TOOLSY_DATA_DIR"] == "/data/demo")
        #expect(variables["TOOLSY_EVENT"] == "command")
        #expect(variables["TOOLSY_COMMAND"] == "apply")
        #expect(variables["TOOLSY_KEY"] == "level")
        #expect(variables["TOOLSY_VALUE"] == "7")
        #expect(variables["TOOLSY_STATE_host"] == "1.1.1.1")
        #expect(variables["TOOLSY_STATE_level"] == "7")
        #expect(variables["TOOLSY_STATE_on"] == "true")
        #expect(variables["TOOLSY_STATE_rows"] == nil)
        #expect(variables["TOOLSY_STATE_nothing"] == nil)
        #expect(variables["PATH"]?.hasPrefix("/opt/homebrew/bin:") == true)
        #expect(variables["HOME"] == ProcessInfo.processInfo.environment["HOME"])
        #expect(variables["LANG"] != nil)
    }

    @Test func rootNeverSearchesUserWritableDirectories() {
        let variables = CommandEnvironment.variables(
            modID: "demo", modDirectory: URL(filePath: "/mods/demo"), dataDirectory: URL(filePath: "/data/demo"),
            input: CommandInput(event: .enable, command: "on", state: [:]), privileged: true
        )
        #expect(variables["PATH"] == "/usr/bin:/bin:/usr/sbin:/sbin")
        #expect(variables["HOME"] == "/var/root")
        #expect(variables["USER"] == "root")
        // The temporary folder of whoever builds the environment: the helper, which is root.
        #expect(variables["TMPDIR"] == NSTemporaryDirectory())
        #expect(variables["SHELL"] == "/bin/sh")
        #expect(variables["TOOLSY_KEY"] == nil)
        #expect(variables["TOOLSY_VALUE"] == nil)
    }

    @Test func inputOmitsAbsentFields() throws {
        let data = try JSONEncoder().encode(CommandInput(event: .refresh, command: "status", state: ["a": 1]))
        let object = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(object == ["event": "refresh", "command": "status", "state": ["a": 1]])
        #expect(try JSONDecoder().decode(CommandInput.self, from: JSONEncoder().encode(input)) == input)
    }

    @Test func buildsInvocations() throws {
        let manifest = try ModManifest.load(from: Data(#"""
        {"schema": 1, "id": "demo", "name": "Demo", "version": "1", "commands": {
            "tool": {"exec": "bin/tool", "args": ["status", "--json"]},
            "script": {"shell": "echo \"$1\"", "args": ["hi"]}
        }}
        """#.utf8))
        let directory = URL(filePath: "/mods/demo", directoryHint: .isDirectory)
        let tool = try #require(manifest.commands["tool"]).invocation(modDirectory: directory)
        #expect(tool.executable.path(percentEncoded: false) == "/mods/demo/bin/tool")
        #expect(tool.arguments == ["status", "--json"])
        let script = try #require(manifest.commands["script"]).invocation(modDirectory: directory)
        #expect(script.executable.path(percentEncoded: false) == "/bin/sh")
        #expect(script.arguments == ["-c", "echo \"$1\"", "toolsy", "hi"])
    }
}
