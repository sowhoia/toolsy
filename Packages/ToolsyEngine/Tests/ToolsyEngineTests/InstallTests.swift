import Foundation
import Testing
@testable import ToolsyEngine
import ToolsyShared

private let toolManifest = manifest(#"""
    "settings": {"host": "1.1.1.1"},
    "commands": {"tool": {"exec": "bin/tool"}, "root": {"shell": "true", "privileged": true}},
    "ui": [{"type": "value", "label": "Host", "value": "{{host}}"}]
    """#)

private func zip(_ folder: URL, to archive: URL, keepParent: Bool) async throws {
    let result = try await ProcessRunner.run(ProcessRunner.Request(
        executable: URL(filePath: "/usr/bin/ditto"),
        arguments: ["-c", "-k"] + (keepParent ? ["--keepParent"] : []) + [folder.path(percentEncoded: false), archive.path(percentEncoded: false)]
    ))
    #expect(result.succeeded)
}

private func permissions(_ url: URL) throws -> Int {
    try #require(FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))[.posixPermissions] as? Int)
}

private func hasQuarantine(_ url: URL) -> Bool {
    getxattr(url.path(percentEncoded: false), "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) >= 0
}

private func rejection(_ package: URL) async -> String {
    do {
        _ = try await ModPackage.validate(package)
        return "no error"
    } catch {
        return error.localizedDescription
    }
}

/// What `prepareInstall` says when it refuses `package`.
@MainActor
private func rejection(_ package: URL, in store: ModStore) async -> String {
    do {
        store.discardInstall(try await store.prepareInstall(from: package))
        return "no error"
    } catch {
        return error.localizedDescription
    }
}

@MainActor @Suite struct InstallTests {
    @Test func installsAFolder() async throws {
        try await withHarness { harness in
            let source = try writeMod(toolManifest, scripts: ["bin/tool": "echo hi"], in: harness.temporary)
            try harness.temporary.write("notes", to: "source/docs/readme.txt")
            try harness.temporary.write("junk", to: "source/.DS_Store")
            let prepared = try await harness.store.prepareInstall(from: source)
            #expect(prepared.manifest.id == "demo")
            #expect(!prepared.replacesInstalledMod && prepared.installedVersion == nil)
            #expect(prepared.privilegedCommands == ["root"])

            let mod = try await harness.store.commitInstall(prepared)
            let installed = harness.directories.mods.appending(path: "demo", directoryHint: .isDirectory)
            #expect(mod.folder.standardizedFileURL == installed.standardizedFileURL)
            #expect(try permissions(installed.appending(path: "bin/tool")) == 0o755)
            #expect(try permissions(installed.appending(path: "docs/readme.txt")) == 0o644)
            #expect(!FileManager.default.fileExists(atPath: installed.appending(path: ".DS_Store").path(percentEncoded: false)))
            #expect(!FileManager.default.fileExists(atPath: prepared.staging.path(percentEncoded: false)), "staging is cleaned up")
            #expect(harness.store.mods.map(\.id) == ["demo"])
            #expect(mod.state["host"] == "1.1.1.1")
        }
    }

    @Test func installsALoneManifest() async throws {
        try await withHarness { harness in
            let file = try harness.temporary.write(manifest(#""commands": {"read": {"shell": "echo 1"}}"#), to: "local.json")
            let mod = try await harness.store.commitInstall(harness.store.prepareInstall(from: file))
            let files = try FileManager.default.contentsOfDirectory(atPath: mod.folder.path(percentEncoded: false))
            #expect(files == ["mod.json"])
        }
    }

    @Test(arguments: [false, true])
    func installsAnArchive(singleTopLevelFolder: Bool) async throws {
        try await withHarness { harness in
            let source = try writeMod(manifest(#""commands": {"tool": {"exec": "bin/tool"}}"#), scripts: ["bin/tool": "echo hi"], in: harness.temporary)
            let archive = harness.temporary.url.appending(path: "demo.toolsymod")
            try await zip(source, to: archive, keepParent: singleTopLevelFolder)
            // A downloaded file: the flag is copied onto everything ditto extracts.
            #expect(setxattr(archive.path(percentEncoded: false), "com.apple.quarantine", "0081;00000000;Safari;", 21, 0, 0) == 0)

            let mod = try await harness.store.commitInstall(harness.store.prepareInstall(from: archive))
            let tool = mod.folder.appending(path: "bin/tool")
            #expect(try permissions(tool) == 0o755)
            #expect(!hasQuarantine(tool) && !hasQuarantine(mod.folder.appending(path: "mod.json")))
            await mod.run("tool")
            #expect(mod.error == nil)
        }
    }

    @Test func discardRemovesTheStagedCopy() async throws {
        try await withHarness { harness in
            let source = try writeMod(manifest(), in: harness.temporary)
            let prepared = try await harness.store.prepareInstall(from: source)
            #expect(FileManager.default.fileExists(atPath: prepared.modDirectory.path(percentEncoded: false)))
            harness.store.discardInstall(prepared)
            #expect(!FileManager.default.fileExists(atPath: prepared.staging.path(percentEncoded: false)))
            await #expect(throws: EngineError.self) { try await harness.store.commitInstall(prepared) }
            #expect(harness.store.mods.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: harness.directories.mods.appending(path: "demo").path(percentEncoded: false)))
        }
    }

    @Test func rejectsBrokenPackages() async throws {
        let directory = try TemporaryDirectory()
        func folder(_ json: String, scripts: [String: String] = [:]) throws -> URL {
            try writeMod(json, scripts: scripts, in: directory, folder: UUID().uuidString)
        }
        #expect(try await rejection(folder(#"{"schema": 1, "id": "demo", "name": "Demo"}"#)) == #"missing required field "version""#)
        #expect(try await rejection(folder(manifest(#""commands": {"tool": {"exec": "bin/tool"}}"#)))
            == #"commands.tool: exec file "bin/tool" is not part of the mod"#)
        let plain = try folder(manifest(#""commands": {"tool": {"exec": "bin/tool"}}"#))
        try directory.write("echo", to: "\(plain.lastPathComponent)/bin/tool")
        #expect(await rejection(plain) == #"commands.tool: exec file "bin/tool" is not executable (chmod +x)"#)

        let linked = try folder(manifest())
        try FileManager.default.createSymbolicLink(at: linked.appending(path: "passwd"), withDestinationURL: URL(filePath: "/etc/passwd"))
        #expect(await rejection(linked).contains("only regular files and folders"))

        #expect(try await rejection(folder(manifest(#""ui": [{"type": "section", "children": [{"type": "divider"}, {"type": "divider", "when": "a =="}]}]"#)))
            == "ui[0].children[1].when: the expression ends where a value is expected")
        #expect(try await rejection(folder(manifest(#""ui": [{"type": "toggle", "label": "T", "bind": "t", "disabled": "(x"}]"#)))
            == #"ui[0].disabled: "(" is not closed"#)
        #expect(try await rejection(folder(manifest(#""ui": [{"type": "divider"}, {"type": "value", "label": "L", "value": "{{v|loud}}"}]"#)))
            == #"ui[1].value: unknown filter "loud""#)
        #expect(try await rejection(folder(manifest(#""ui": [{"type": "row", "children": [{"type": "button", "label": "{{a", "open": "https://x.org"}]}]"#)))
            == #"ui[0].children[0].label: "{{" is not closed"#)
        #expect(try await rejection(folder(manifest(#""ui": [{"type": "section", "title": "ok", "footer": "}}", "children": []}]"#)))
            == #"ui[0].footer: "}}" has no matching "{{""#)

        let text = try directory.write("x", to: "notes.txt")
        #expect(await rejection(text).contains("is not a mod"))
        #expect(await rejection(directory.url.appending(path: "missing.toolsymod")).contains("cannot be read"))
        let notAnArchive = try directory.write("plain text", to: "fake.toolsymod")
        #expect(await rejection(notAnArchive).contains("is not a zip archive"))

        let twoFolders = directory.url.appending(path: "two", directoryHint: .isDirectory)
        try directory.write(manifest(), to: "two/a/mod.json")
        try directory.write(manifest(), to: "two/b/mod.json")
        let archive = directory.url.appending(path: "two.toolsymod")
        try await zip(twoFolders, to: archive, keepParent: false)
        #expect(await rejection(archive).contains("no mod.json at its root or inside a single top-level folder"))
    }

    @Test func refusesAnArchiveThatDeclaresMoreThanAModMayHold() async throws {
        // 65 MB of zeros compress to a few kilobytes: the archive is tiny, what it would unpack is not.
        let directory = try TemporaryDirectory()
        try directory.write(manifest(), to: "bomb/mod.json")
        let filler = try directory.write("", to: "bomb/filler.bin")
        let handle = try FileHandle(forWritingTo: filler)
        try handle.truncate(atOffset: UInt64(ModPayload.maxTotalBytes + 1024 * 1024))
        try handle.close()
        let archive = directory.url.appending(path: "bomb.toolsymod")
        try await zip(directory.url.appending(path: "bomb", directoryHint: .isDirectory), to: archive, keepParent: false)
        try FileManager.default.removeItem(at: filler)
        let archiveSize = try #require(try archive.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        #expect(archiveSize < 1024 * 1024)

        try await withHarness { harness in
            let message = await rejection(archive, in: harness.store)
            #expect(message.contains("more than a mod may hold"))
            let leftovers = try FileManager.default.subpathsOfDirectory(atPath: harness.directories.root.path(percentEncoded: false))
            #expect(!leftovers.contains { $0.hasSuffix("filler.bin") }, "nothing was unpacked")
        }
    }

    @Test func stopsUnpackingAnArchiveThatHoldsMoreThanItDeclares() async throws {
        // Half a gigabyte of zeros in an archive of well under a megabyte.
        let size = 512 * 1024 * 1024
        let directory = try TemporaryDirectory()
        try directory.write(manifest(), to: "bomb/mod.json")
        let filler = try directory.write("", to: "bomb/filler.bin")
        let handle = try FileHandle(forWritingTo: filler)
        try handle.truncate(atOffset: UInt64(size))
        try handle.close()
        let archive = directory.url.appending(path: "bomb.toolsymod")
        try await zip(directory.url.appending(path: "bomb", directoryHint: .isDirectory), to: archive, keepParent: false)
        try FileManager.default.removeItem(at: filler)

        // The archive's directory is its author's word. Make it claim that the filler unpacks to ten bytes:
        // the size is the four bytes at offset 24 of the entry's central header ("PK\u{1}\u{2}").
        var bytes = try Data(contentsOf: archive)
        let entry = try #require(bytes.ranges(of: Data("PK\u{1}\u{2}".utf8)).first { header in
            bytes[header.lowerBound...].dropFirst(46).starts(with: Data("filler.bin".utf8))
        })
        bytes.replaceSubrange(entry.lowerBound + 24 ..< entry.lowerBound + 28, with: [10, 0, 0, 0])
        try bytes.write(to: archive)

        try await withHarness { harness in
            let message = await rejection(archive, in: harness.store)
            #expect(message.contains("unpacks to more than a mod may hold"))
            let leftovers = try FileManager.default.subpathsOfDirectory(atPath: harness.directories.root.path(percentEncoded: false))
            #expect(!leftovers.contains { $0.hasSuffix("filler.bin") }, "what was unpacked is gone")
        }
    }

    @Test func removesAModThatCannotBeLoaded() async throws {
        let helper = FakeHelper(status: .ready)
        try await withHarness(helper: helper) { harness in
            try harness.temporary.write(#"{"schema": 1, "id": "broken"}"#, to: "Toolsy/Mods/broken/mod.json")
            await helper.set(approval: "digest", for: "broken")
            try harness.temporary.write(#"{"enabled": true, "settings": {}}"#, to: "Toolsy/State/broken.json")
            try harness.temporary.write("data", to: "Toolsy/Data/broken/file")
            try await harness.install(manifest(id: "fine"))
            await harness.relaunch()
            let problem = try #require(harness.store.loadProblems.first)
            #expect(problem.folder == "broken" && harness.store.mods.map(\.id) == ["fine"])

            try await harness.store.removeBrokenMod(problem)
            #expect(harness.store.loadProblems.isEmpty)
            for path in ["Mods/broken", "State/broken.json", "Data/broken"] {
                #expect(!FileManager.default.fileExists(atPath: harness.directories.root.appending(path: path).path(percentEncoded: false)), "\(path) is gone")
            }
            #expect(await helper.calls == ["revoke broken"])
            #expect(harness.store.mods.map(\.id) == ["fine"], "other mods are untouched")
        }
    }

    @Test func updateReplacesFilesAndKeepsSettings() async throws {
        try await withHarness { harness in
            let first = try await harness.install(
                manifest(version: "1", #""settings": {"host": "a", "old": 1}, "commands": {"on": {"shell": "true"}}, "lifecycle": {"enable": "on"}"#)
            )
            first.setValue("custom", for: "host")
            await first.setEnabled(true)
            #expect(first.isEnabled)

            let source = try writeMod(
                manifest(version: "2", #""settings": {"host": "b", "added": true}, "commands": {"on": {"shell": "true"}}, "lifecycle": {"enable": "on"}"#),
                in: harness.temporary
            )
            let prepared = try await harness.store.prepareInstall(from: source)
            #expect(prepared.replacesInstalledMod && prepared.installedVersion == "1")
            let second = try await harness.store.commitInstall(prepared)

            #expect(second.manifest.version == "2")
            #expect(second.state["host"] == "custom" && second.state["added"] == true && second.state["old"] == nil)
            #expect(second.isEnabled)
            #expect(harness.store.mods.count == 1 && harness.store.mods[0] === second)
            // The replaced object is inert.
            await first.run("on")
            #expect(first.runningCommands.isEmpty)
        }
    }

    @Test func failedInstallLeavesThePreviousVersionIntact() async throws {
        try await withHarness { harness in
            try await harness.install(manifest(version: "1", #""commands": {"tool": {"exec": "bin/tool"}}"#), scripts: ["bin/tool": "echo v1"])
            let installedManifest = harness.directories.mods.appending(path: "demo/mod.json")
            let before = try Data(contentsOf: installedManifest)

            let broken = try writeMod(manifest(version: "2", #""commands": {"tool": {"exec": "bin/other"}}"#), in: harness.temporary)
            await #expect(throws: ManifestError.self) { try await harness.store.prepareInstall(from: broken) }

            #expect(try Data(contentsOf: installedManifest) == before)
            #expect(try harness.mod().manifest.version == "1")
            let tool = harness.directories.mods.appending(path: "demo/bin/tool")
            #expect(try String(contentsOf: tool, encoding: .utf8).contains("echo v1"))
        }
    }

    @Test func oneBrokenModDoesNotStopTheOthers() async throws {
        try await withHarness { harness in
            try await harness.install(manifest(id: "good"))
            try harness.temporary.write("{ not json", to: "Toolsy/Mods/broken/mod.json")
            try harness.temporary.write(manifest(id: "other"), to: "Toolsy/Mods/misnamed/mod.json")
            await harness.relaunch()
            #expect(harness.store.mods.map(\.id) == ["good"])
            #expect(harness.store.loadProblems.map(\.folder) == ["broken", "misnamed"])
            #expect(harness.store.loadProblems[0].message.contains("not valid JSON"))
            #expect(harness.store.loadProblems[1].message.contains("does not match"))

            // Installing a mod with a broken folder's id replaces it and clears the problem.
            try await harness.install(manifest(id: "broken"))
            #expect(harness.store.mods.map(\.id).sorted() == ["broken", "good"])
            #expect(harness.store.loadProblems.map(\.folder) == ["misnamed"])
        }
    }

    @Test func listsModsByName() async throws {
        try await withHarness { harness in
            try await harness.install(manifest(id: "z", name: "alpha"))
            try await harness.install(manifest(id: "a", name: "Beta"))
            try await harness.install(manifest(id: "m", name: "Alpha 10"))
            try await harness.install(manifest(id: "n", name: "Alpha 9"))
            #expect(harness.store.mods.map(\.id) == ["z", "n", "m", "a"])
            await harness.relaunch()
            #expect(harness.store.mods.map(\.id) == ["z", "n", "m", "a"])
        }
    }
}
