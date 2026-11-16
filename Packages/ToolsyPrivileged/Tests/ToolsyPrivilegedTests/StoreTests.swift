import Foundation
import Testing
@testable import ToolsyHelperCore
import ToolsyShared

@Suite struct StoreTests {
    @Test func approvesWithExplicitModesWhateverTheUmask() async throws {
        let directory = try TemporaryDirectory()
        let service = HelperService(store: try makeStore(in: directory), installedFiles: [])
        let previous = umask(0o077)
        defer { umask(previous) }
        try await service.approve(modID: ProbeMod.id, files: ProbeMod.files(), executables: ProbeMod.executables)

        // Only the owner gets into the store's two folders, so the modes below them matter to the owner alone.
        #expect(try mode(of: service.store.mods) == 0o700)
        #expect(try mode(of: service.store.data) == 0o700)
        let snapshot = service.store.snapshotDirectory(ProbeMod.id)
        #expect(try mode(of: snapshot) == 0o755)
        #expect(try mode(of: snapshot.appending(path: "bin")) == 0o755)
        #expect(try mode(of: snapshot.appending(path: "bin/probe.sh")) == 0o755)
        #expect(try mode(of: snapshot.appending(path: "mod.json")) == 0o644)
        #expect(try mode(of: snapshot.appending(path: "docs/readme.txt")) == 0o644)
        #expect(try owner(of: snapshot.appending(path: "mod.json")) == getuid())
        #expect(try Data(contentsOf: snapshot.appending(path: "docs/readme.txt")) == Data("notes".utf8))
        #expect(try ModPayload(directory: snapshot) == ProbeMod.payload())
        #expect(try service.approvedMods() == [ProbeMod.id: ProbeMod.payload().digest])
    }

    @Test func replacesWholeSnapshot() async throws {
        let directory = try TemporaryDirectory()
        let service = HelperService(store: try makeStore(in: directory), installedFiles: [])
        try await service.approve(modID: ProbeMod.id, files: ProbeMod.files(extra: ["old.txt": "old"]), executables: ProbeMod.executables)
        try await service.approve(modID: ProbeMod.id, files: ProbeMod.files(version: "2"), executables: ProbeMod.executables)

        let snapshot = service.store.snapshotDirectory(ProbeMod.id)
        #expect(!FileManager.default.fileExists(atPath: snapshot.appending(path: "old.txt").path(percentEncoded: false)))
        #expect(try ModPayload(directory: snapshot) == ProbeMod.payload(version: "2"))
        #expect(try service.approvedMods() == [ProbeMod.id: ProbeMod.payload(version: "2").digest])
        // Neither the previous snapshot nor a staging directory is left behind.
        #expect(try FileManager.default.contentsOfDirectory(atPath: service.store.mods.path(percentEncoded: false)) == [ProbeMod.id])
    }

    @Test func runsNeverSeeASnapshotBeingReplaced() async throws {
        let directory = try TemporaryDirectory()
        let service = HelperService(store: try makeStore(in: directory), installedFiles: [])
        try await service.approve(modID: ProbeMod.id, files: ProbeMod.files(), executables: ProbeMod.executables)
        let input = try ProbeMod.encoded(ProbeMod.input("env"))
        try await withThrowingTaskGroup { group in
            group.addTask {
                for round in 1...30 {
                    // An approval is refused while a run holds the snapshot, so it slips in between two runs.
                    while true {
                        do {
                            try await service.approve(modID: ProbeMod.id, files: ProbeMod.files(version: "\(round)"), executables: ProbeMod.executables)
                            break
                        } catch HelperError.busy {
                            await Task.yield()
                        }
                    }
                }
            }
            group.addTask {
                for _ in 1...30 {
                    let output = keyValues(try await service.run(modID: ProbeMod.id, command: "env", input: input).stdout)
                    // The program and a data file of the same snapshot always agree.
                    #expect(output["version"] != nil && output["version"] == output["file"])
                }
            }
            try await group.waitForAll()
        }
    }

    @Test func leftoversOfACrashedApprovalAreIgnoredAndCleanedUp() async throws {
        let directory = try TemporaryDirectory()
        let service = HelperService(store: try makeStore(in: directory), installedFiles: [])
        try await service.approve(modID: ProbeMod.id, files: ProbeMod.files(), executables: ProbeMod.executables)
        // What a crash between writing the staging copy and the swap leaves behind.
        let staging = service.store.mods.appending(path: ".\(ProbeMod.id).staging")
        try FileManager.default.createDirectory(at: staging.appending(path: "bin"), withIntermediateDirectories: true)
        try Data("#!/bin/sh\necho half-written\n".utf8).write(to: staging.appending(path: "bin/probe.sh"))

        #expect(try service.approvedMods() == [ProbeMod.id: ProbeMod.payload().digest])
        let result = try await service.run(modID: ProbeMod.id, command: "env", input: ProbeMod.encoded(ProbeMod.input("env")))
        #expect(keyValues(result.stdout)["version"] == "1")

        try await service.approve(modID: ProbeMod.id, files: ProbeMod.files(version: "2"), executables: ProbeMod.executables)
        #expect(try FileManager.default.contentsOfDirectory(atPath: service.store.mods.path(percentEncoded: false)) == [ProbeMod.id])
    }

    @Test func revokeDeletesSnapshotAndData() async throws {
        let directory = try TemporaryDirectory()
        let service = HelperService(store: try makeStore(in: directory), installedFiles: [])
        try await service.approve(modID: ProbeMod.id, files: ProbeMod.files(), executables: ProbeMod.executables)
        try await service.approve(modID: "other", files: ProbeMod.files(id: "other"), executables: ProbeMod.executables)
        _ = try await service.run(modID: ProbeMod.id, command: "env", input: ProbeMod.encoded(ProbeMod.input("env")))
        #expect(FileManager.default.fileExists(atPath: service.store.dataDirectory(ProbeMod.id).path(percentEncoded: false)))

        try await service.revoke(modID: ProbeMod.id, keepingData: false)
        #expect(try service.approvedMods().keys.sorted() == ["other"])
        #expect(!FileManager.default.fileExists(atPath: service.store.dataDirectory(ProbeMod.id).path(percentEncoded: false)))
        #expect(try FileManager.default.contentsOfDirectory(atPath: service.store.mods.path(percentEncoded: false)) == ["other"])
        // Revoking what is not approved is not an error.
        try await service.revoke(modID: ProbeMod.id, keepingData: false)
    }

    @Test func revokeCanLeaveTheDataAlone() async throws {
        let directory = try TemporaryDirectory()
        let service = HelperService(store: try makeStore(in: directory), installedFiles: [])
        try await service.approve(modID: ProbeMod.id, files: ProbeMod.files(), executables: ProbeMod.executables)
        _ = try await service.run(modID: ProbeMod.id, command: "settle", input: ProbeMod.encoded(ProbeMod.input("settle")))
        let written = service.store.dataDirectory(ProbeMod.id).appending(path: "finished").path(percentEncoded: false)
        #expect(FileManager.default.fileExists(atPath: written))

        try await service.revoke(modID: ProbeMod.id, keepingData: true)
        #expect(try service.approvedMods().isEmpty)
        #expect(FileManager.default.fileExists(atPath: written), "only the approval is gone")
    }

    @Test(arguments: [
        ["../escape": "x"],
        ["/etc/passwd": "x"],
        ["bin/./probe.sh": "x"],
        ["a//b": "x"],
        ["with\u{1}control": "x"],
        ["back\\slash": "x"],
        ["MOD.JSON": "x"],
        ["docs": "x"],
    ])
    func refusesHostilePaths(_ extra: [String: String]) async throws {
        let directory = try TemporaryDirectory()
        let service = HelperService(store: try makeStore(in: directory), installedFiles: [])
        var files = ProbeMod.files()
        for (path, contents) in extra { files[path] = Data(contents.utf8) }
        await #expect(throws: HelperError.self) {
            try await service.approve(modID: ProbeMod.id, files: files, executables: ProbeMod.executables)
        }
        #expect(try service.approvedMods().isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: service.store.mods.path(percentEncoded: false)).isEmpty)
    }

    @Test func refusesPayloadsThatBreakTheApprovalRules() throws {
        func failure(_ modID: String = ProbeMod.id, files: [String: Data] = ProbeMod.files(), executables: [String] = ProbeMod.executables) -> String {
            do {
                _ = try HelperService.validatedPayload(modID: modID, files: files, executables: executables)
                return "accepted"
            } catch {
                return error.localizedDescription
            }
        }
        #expect(failure() == "accepted")
        #expect(failure("Bad/ID") == "invalid mod id")
        #expect(failure("other") == "mod.json declares the id probe, not other")
        #expect(failure(executables: []) == "commands.env: bin/probe.sh is not executable")
        #expect(failure(executables: ["missing"]).contains("not part of the mod"))

        var withoutProgram = ProbeMod.files()
        withoutProgram["bin/probe.sh"] = nil
        #expect(failure(files: withoutProgram, executables: []) == "commands.env: bin/probe.sh is not part of the mod")

        let unprivileged = #"{"schema": 1, "id": "probe", "name": "P", "version": "1", "commands": {"a": {"shell": "true"}}}"#
        #expect(failure(files: ["mod.json": Data(unprivileged.utf8)], executables: []) == "probe declares no privileged command")
        #expect(failure(files: ["mod.json": Data("{".utf8)], executables: []).hasPrefix("mod.json: "))
        #expect(failure(files: ["other.txt": Data()], executables: []) == "mod.json is missing")
    }

    @Test func refusesAStoreOthersCouldWrite() throws {
        let directory = try TemporaryDirectory()
        let root = directory.path("store")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: root.path(percentEncoded: false))
        #expect(throws: HelperError.self) { try ModStore(root: root, ownerUID: getuid()) }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path(percentEncoded: false))
        #expect(throws: HelperError.self) { try ModStore(root: root, ownerUID: getuid() + 1) }
        _ = try ModStore(root: root, ownerUID: getuid())

        let link = directory.path("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        #expect(throws: HelperError.self) { try ModStore(root: link, ownerUID: getuid()) }
    }

    @Test func loadsOnlyAProtectedWellFormedRequirement() throws {
        let directory = try TemporaryDirectory()
        let hash = String(repeating: "ab", count: 20)
        let file = try directory.write(requirement(cdhash: hash), to: "client-requirement")
        #expect(try ClientRequirement.load(from: file, ownerUID: getuid()) == "cdhash H\"\(hash)\"")
        #expect(throws: HelperError.self) { try ClientRequirement.load(from: file, ownerUID: getuid() + 1) }

        for writable in [0o664, 0o646] {
            try FileManager.default.setAttributes([.posixPermissions: writable], ofItemAtPath: file.path(percentEncoded: false))
            #expect(throws: HelperError.self) { try ClientRequirement.load(from: file, ownerUID: getuid()) }
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path(percentEncoded: false))

        for malformed in [
            "", "cdhash H\"\(hash)\"\n", "cdhash H\"\(hash.uppercased())\"", "cdhash H\"\(hash.dropLast())\"",
            "anchor apple", "cdhash H\"\(hash)\" or anchor apple",
        ] {
            try Data(malformed.utf8).write(to: file)
            #expect(throws: HelperError.self, "\(malformed)") { try ClientRequirement.load(from: file, ownerUID: getuid()) }
        }
        #expect(throws: HelperError.self) { try ClientRequirement.load(from: directory.path("missing"), ownerUID: getuid()) }
    }

    @Test func loadsOnlyAProtectedWellFormedUser() throws {
        let directory = try TemporaryDirectory()
        let file = try directory.write("501", to: "client-user")
        #expect(try ClientUser.load(from: file, ownerUID: getuid()) == 501)
        #expect(throws: HelperError.self) { try ClientUser.load(from: file, ownerUID: getuid() + 1) }
        try FileManager.default.setAttributes([.posixPermissions: 0o646], ofItemAtPath: file.path(percentEncoded: false))
        #expect(throws: HelperError.self) { try ClientUser.load(from: file, ownerUID: getuid()) }
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path(percentEncoded: false))

        for malformed in ["", "501\n", "-1", "0x1f5", "501 0", "99999999999"] {
            try Data(malformed.utf8).write(to: file)
            #expect(throws: HelperError.self, "\(malformed)") { try ClientUser.load(from: file, ownerUID: getuid()) }
        }
        #expect(throws: HelperError.self) { try ClientUser.load(from: directory.path("missing"), ownerUID: getuid()) }
    }
}
