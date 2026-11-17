import CryptoKit
import Foundation
import Synchronization
import Testing
import ToolsyShared
@testable import Toolsy

// MARK: - Fixtures

private struct FixtureError: Error, CustomStringConvertible {
    let description: String
}

/// Runs a tool to its end; its failure is the test's. It never blocks the main actor, which the tests of the panel's
/// sampling and of developer mode wait on meanwhile.
private nonisolated func run(_ tool: String, _ arguments: [String]) async throws {
    let result = try await ProcessRunner.run(ProcessRunner.Request(
        executable: URL(filePath: tool), arguments: arguments, environment: ProcessInfo.processInfo.environment, timeout: 300
    ))
    guard result.succeeded else {
        throw FixtureError(description: "\(tool) \(arguments.joined(separator: " ")): \(String(decoding: result.stderr, as: UTF8.self))")
    }
}

private func temporaryFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appending(path: "ToolsyUpdate-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

/// Removes a temporary folder, making it writable again first.
private func removeFolder(_ folder: URL) {
    try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path(percentEncoded: false))
    try? FileManager.default.removeItem(at: folder)  // best effort: a temporary folder
}

/// An app like Toolsy's, signed ad hoc: an executable (`/usr/bin/true`, or one slice of it), its Info.plist and a
/// resource that tells the versions apart.
private func makeApp(at app: URL, identifier: String = "app.toolsy.test", version: String, minimumSystem: String = "26.0",
                     architecture: String? = nil) async throws {
    let contents = app.appending(path: "Contents", directoryHint: .isDirectory)
    let files = FileManager.default
    try files.createDirectory(at: contents.appending(path: "MacOS"), withIntermediateDirectories: true)
    try files.createDirectory(at: contents.appending(path: "Resources"), withIntermediateDirectories: true)
    let info: [String: Any] = [
        "CFBundleExecutable": "Fixture", "CFBundleIdentifier": identifier, "CFBundleInfoDictionaryVersion": "6.0",
        "CFBundlePackageType": "APPL", "CFBundleShortVersionString": version, "LSMinimumSystemVersion": minimumSystem,
    ]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appending(path: "Info.plist"))
    let executable = contents.appending(path: "MacOS/Fixture").path(percentEncoded: false)
    if let architecture {
        try await run("/usr/bin/lipo", ["/usr/bin/true", "-thin", architecture, "-output", executable])
    } else {
        try files.copyItem(atPath: "/usr/bin/true", toPath: executable)
    }
    try Data("Toolsy \(version)".utf8).write(to: contents.appending(path: "Resources/version.txt"))
    try await run("/usr/bin/codesign", ["--force", "--sign", "-", app.path(percentEncoded: false)])
}

/// The version an app on disk says it is, read without `Bundle`, which keeps what it once read of a path.
private func versionOfApp(at app: URL) -> String? {
    guard let data = try? Data(contentsOf: app.appending(path: "Contents/Info.plist")),
          let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
    return info["CFBundleShortVersionString"] as? String
}

private func hex(_ digest: SHA256.Digest) -> String {
    digest.map { String(format: "%02x", $0) }.joined()
}

/// The signature file of `archive` as `scripts/sign-update.swift` writes it, made with `key`.
private func signatureFile(for archive: Data, version: String, key: Curve25519.Signing.PrivateKey) throws -> Data {
    let sha256 = hex(SHA256.hash(data: archive))
    let signature = try key.signature(for: UpdateSignature.message(version: version, size: Int64(archive.count), sha256: sha256))
    let file: [String: Any] = ["format": 1, "version": version, "size": archive.count, "sha256": sha256,
                               "signature": signature.base64EncodedString()]
    return try JSONSerialization.data(withJSONObject: file, options: .sortedKeys)
}

private func isUnverified(_ error: UpdateInstallError?) -> Bool {
    if case .unverified = error { true } else { false }
}

// MARK: - The signature

struct UpdateSignatureTests {
    let key = Curve25519.Signing.PrivateKey()
    let archive = Data("the archive of Toolsy 1.2.0".utf8)

    @Test func theReleaseKeyVouchesForTheArchiveOfAVersion() throws {
        let signed = try UpdateSignature.verify(try signatureFile(for: archive, version: "1.2.0", key: key), with: key.publicKey)
        #expect(signed == UpdateSignature(version: ReleaseVersion("1.2.0")!, size: Int64(archive.count), sha256: hex(SHA256.hash(data: archive))))
    }

    @Test func anythingElseIsRefused() throws {
        func refusal(_ file: Data, key: Curve25519.Signing.PublicKey? = nil) -> UpdateInstallError? {
            do {
                _ = try UpdateSignature.verify(file, with: key ?? self.key.publicKey)
                return nil
            } catch {
                return error
            }
        }
        let signed = try signatureFile(for: archive, version: "1.2.0", key: key)
        #expect(refusal(signed) == nil)
        #expect(isUnverified(refusal(signed, key: Curve25519.Signing.PrivateKey().publicKey)), "another key")
        let fields = try #require(try JSONSerialization.jsonObject(with: signed) as? [String: Any])
        let changes: [(String, Any)] = [
            ("version", "1.3.0"), ("size", archive.count + 1), ("sha256", String(repeating: "0", count: 64)),
            ("sha256", hex(SHA256.hash(data: archive)).uppercased()), ("format", 2), ("signature", "not base64"),
            ("version", "latest"), ("size", 0),
        ]
        for (field, value) in changes {
            var changed = fields
            changed[field] = value
            #expect(isUnverified(refusal(try JSONSerialization.data(withJSONObject: changed))), "\(field): \(value)")
        }
        var missing = fields
        missing["sha256"] = nil
        #expect(isUnverified(refusal(try JSONSerialization.data(withJSONObject: missing))))
        #expect(isUnverified(refusal(Data("<html>".utf8))))
        var padded = fields
        padded["padding"] = String(repeating: " ", count: Int(UpdateSignature.maxFileSize))
        #expect(isUnverified(refusal(try JSONSerialization.data(withJSONObject: padded))), "longer than a signature can be")
    }

    /// `scripts/sign-update.swift` and the app agree on what is signed: what the script writes passes the app's check, and
    /// the script refuses a key that Info.plist does not name.
    @Test(.timeLimit(.minutes(3))) func theReleaseScriptSignsWhatTheAppChecks() async throws {
        let repository = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let scratch = try temporaryFolder()
        defer { removeFolder(scratch) }
        // The script finds Resources/Info.plist next to its own folder: a copy of it beside an Info.plist that trusts a key
        // made here, never the release key.
        let script = scratch.appending(path: "scripts/sign-update.swift")
        try FileManager.default.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: repository.appending(path: "scripts/sign-update.swift"), to: script)
        try FileManager.default.createDirectory(at: scratch.appending(path: "Resources"), withIntermediateDirectories: true)
        let key = Curve25519.Signing.PrivateKey()
        try PropertyListSerialization.data(fromPropertyList: [UpdateSignature.infoKey: key.publicKey.rawRepresentation.base64EncodedString()],
                                           format: .xml, options: 0)
            .write(to: scratch.appending(path: "Resources/Info.plist"))
        func keyFile(_ key: Curve25519.Signing.PrivateKey, named name: String) throws -> String {
            let file = scratch.appending(path: name)
            try Data(#"{"toolsySigningKey":1,"privateKey":"\#(key.rawRepresentation.base64EncodedString())"}"#.utf8).write(to: file)
            return file.path(percentEncoded: false)
        }
        let archive = scratch.appending(path: "Toolsy-1.2.0.zip")
        let bytes = Data((0..<5000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        try bytes.write(to: archive)

        try await run("/usr/bin/xcrun", ["swift", script.path(percentEncoded: false), try keyFile(key, named: "release.key"), "1.2.0",
                                         archive.path(percentEncoded: false)])
        let signed = try UpdateSignature.verify(try Data(contentsOf: scratch.appending(path: "Toolsy-1.2.0.zip.sig")), with: key.publicKey)
        #expect(signed == UpdateSignature(version: ReleaseVersion("1.2.0")!, size: Int64(bytes.count), sha256: hex(SHA256.hash(data: bytes))))

        let otherKey = try keyFile(Curve25519.Signing.PrivateKey(), named: "other.key")
        await #expect(throws: FixtureError.self, "a key Info.plist does not name") {
            try await run("/usr/bin/xcrun", ["swift", script.path(percentEncoded: false), otherKey, "1.2.0", archive.path(percentEncoded: false)])
        }
    }
}

// MARK: - The app in the archive

struct UpdateBundleCheckTests {
    private func expectation(_ version: String = "1.2.0", team: String? = nil) -> UpdateBundleCheck.Expectation {
        UpdateBundleCheck.Expectation(identifier: "app.toolsy.test", version: ReleaseVersion(version)!, team: team)
    }

    private func failure(in folder: URL, expecting expected: UpdateBundleCheck.Expectation) -> UpdateInstallError? {
        do {
            _ = try UpdateBundleCheck.app(in: folder, expecting: expected)
            return nil
        } catch {
            return error as? UpdateInstallError
        }
    }

    @Test func theUpdateIsThisAppInTheVersionSigned() async throws {
        let folder = try temporaryFolder()
        defer { removeFolder(folder) }
        try await makeApp(at: folder.appending(path: "Toolsy.app"), version: "1.2.0")
        // What Finder's Compress adds next to the app is not another app.
        try FileManager.default.createDirectory(at: folder.appending(path: "__MACOSX"), withIntermediateDirectories: true)
        let app = try UpdateBundleCheck.app(in: folder, expecting: expectation())
        #expect(app.lastPathComponent == "Toolsy.app")
        #expect(isUnverified(failure(in: folder, expecting: expectation("1.2.1"))), "another version")
        #expect(isUnverified(failure(in: folder, expecting: UpdateBundleCheck.Expectation(identifier: "app.toolsy",
                                                                                          version: ReleaseVersion("1.2.0")!, team: nil))))
        #expect(isUnverified(failure(in: folder, expecting: expectation(team: "ABCDE12345"))), "not signed by the running app's team")
    }

    @Test func anythingButOneAppIsRefused() async throws {
        let empty = try temporaryFolder()
        defer { removeFolder(empty) }
        #expect(isUnverified(failure(in: empty, expecting: expectation())))

        let two = try temporaryFolder()
        defer { removeFolder(two) }
        try await makeApp(at: two.appending(path: "Toolsy.app"), version: "1.2.0")
        try await makeApp(at: two.appending(path: "Other.app"), version: "1.2.0")
        #expect(isUnverified(failure(in: two, expecting: expectation())))

        let linked = try temporaryFolder()
        defer { removeFolder(linked) }
        try FileManager.default.createSymbolicLink(at: linked.appending(path: "Toolsy.app"), withDestinationURL: two.appending(path: "Toolsy.app"))
        #expect(isUnverified(failure(in: linked, expecting: expectation())), "a link to an app elsewhere")
    }

    @Test func anAppChangedAfterItWasSignedIsRefused() async throws {
        let folder = try temporaryFolder()
        defer { removeFolder(folder) }
        let app = folder.appending(path: "Toolsy.app")
        try await makeApp(at: app, version: "1.2.0")
        try Data("changed".utf8).write(to: app.appending(path: "Contents/Resources/version.txt"))
        #expect(isUnverified(failure(in: folder, expecting: expectation())))
    }

    @Test func anUpdateForANewerSystemOrAnotherProcessorSaysSo() async throws {
        let newer = try temporaryFolder()
        defer { removeFolder(newer) }
        try await makeApp(at: newer.appending(path: "Toolsy.app"), version: "1.2.0", minimumSystem: "99.0")
        #expect(failure(in: newer, expecting: expectation()) == .needsNewerSystem(update: "1.2.0", system: "99.0"))

        let other = try temporaryFolder()
        defer { removeFolder(other) }
        #if arch(arm64)
        let otherArchitecture = "x86_64"
        #else
        let otherArchitecture = "arm64e"
        #endif
        try await makeApp(at: other.appending(path: "Toolsy.app"), version: "1.2.0", architecture: otherArchitecture)
        #expect(failure(in: other, expecting: expectation()) == .unsupportedMac(update: "1.2.0"))
        #expect(!UpdateInstallError.unsupportedMac(update: "1.2.0").isWorthRetrying)
    }
}

// MARK: - Taking the app's place

struct AppReplacementTests {
    @Test func whatKeepsACopyFromReplacingItself() throws {
        #expect(AppReplacement.obstacle(for: URL(filePath: "/Users/someone/toolsy/.build/debug", directoryHint: .isDirectory)) == .unsupportedBuild)
        #expect(AppReplacement.obstacle(for: URL(filePath: "/private/var/folders/x/T/AppTranslocation/1F2E/d/Toolsy.app")) == .translocated)
        let folder = try temporaryFolder()
        defer { removeFolder(folder) }
        let app = folder.appending(path: "Toolsy.app", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        #expect(AppReplacement.obstacle(for: app) == nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path(percentEncoded: false))
        #expect(AppReplacement.obstacle(for: app) == .permission)
    }

    @Test func theUpdateAndTheAppSwapPlacesInOneStep() async throws {
        let folder = try temporaryFolder()
        defer { removeFolder(folder) }
        let installed = folder.appending(path: "Toolsy.app", directoryHint: .isDirectory)
        try await makeApp(at: installed, version: "1.1.0")
        let staging = try AppReplacement.stagingFolder(for: installed)
        let update = staging.appending(path: "Toolsy.app", directoryHint: .isDirectory)
        try await makeApp(at: update, version: "1.2.0")

        try AppReplacement.swap(update, into: installed)
        #expect(versionOfApp(at: installed) == "1.2.0")
        #expect(versionOfApp(at: update) == "1.1.0")

        // Nothing to swap with: nothing changes.
        AppReplacement.remove(staging)
        #expect(!FileManager.default.fileExists(atPath: staging.path(percentEncoded: false)))
        #expect(throws: UpdateInstallError.self) { try AppReplacement.swap(update, into: installed) }
        #expect(versionOfApp(at: installed) == "1.2.0")
    }
}

// MARK: - The installer

/// An installed app, releases served for it, and what the installer did with them.
@MainActor
private final class InstallFixture {
    let folder: URL
    let installed: URL
    let key = Curve25519.Signing.PrivateKey()
    var trusted = true
    /// What each file of a release is, by name.
    var files: [String: Data] = [:]
    private(set) var downloads: [String] = []
    var failNextDownload: (any Error)?
    /// The archive's download waits until it is cancelled.
    var holdsArchive = false
    /// How many times the installer is told that something is in progress before it may go on.
    var busyAnswers = 0
    private(set) var busyQuestions = 0
    private(set) var restarts: [URL] = []
    var restartError: (any Error)?

    init() async throws {
        folder = try temporaryFolder()
        installed = folder.appending(path: "Applications/Toolsy.app", directoryHint: .isDirectory)
        try await makeApp(at: installed, version: "1.1.0")
    }

    lazy var installer = UpdateInstaller(environment: UpdateInstaller.Environment(
        bundle: installed, identifier: "app.toolsy.test", team: nil, trustedKey: trusted ? key.publicKey : nil,
        download: { [weak self] url, destination, limit, progress in
            try await self?.serve(url, to: destination, limit: limit, progress: progress)
        },
        isBusy: { [weak self] in self?.isBusy() ?? false },
        restart: { [weak self] bundle in try self?.restart(bundle) }
    ))

    /// Publishes a release of `version`: the archive of an app (in `appVersion`, `version` unless given) and its signature
    /// by `signer` (the release key unless given) as `signedVersion` (`version` unless given). `tamper` changes the
    /// archive after it was signed.
    func publish(_ version: String, appVersion: String? = nil, identifier: String = "app.toolsy.test", minimumSystem: String = "26.0",
                 signer: Curve25519.Signing.PrivateKey? = nil, signedVersion: String? = nil,
                 tamper: ((inout Data) -> Void)? = nil) async throws -> LatestRelease {
        let build = folder.appending(path: "build-\(UUID().uuidString)/Toolsy.app", directoryHint: .isDirectory)
        try await makeApp(at: build, identifier: identifier, version: appVersion ?? version, minimumSystem: minimumSystem)
        let zip = folder.appending(path: "Toolsy-\(UUID().uuidString).zip")
        try await run("/usr/bin/ditto", ["-c", "-k", "--norsrc", "--noextattr", "--keepParent", build.path(percentEncoded: false),
                                         zip.path(percentEncoded: false)])
        var archive = try Data(contentsOf: zip)
        let signature = try signatureFile(for: archive, version: signedVersion ?? version, key: signer ?? key)
        tamper?(&archive)
        let name = "Toolsy-\(version).zip"
        files[name] = archive
        files[name + ".sig"] = signature
        let downloads = "https://github.com/sowhoia/toolsy/releases/download/v\(version)/"
        return LatestRelease(
            version: ReleaseVersion(version)!, page: URL(string: "https://github.com/sowhoia/toolsy/releases/tag/v\(version)")!,
            package: UpdatePackage(archive: URL(string: downloads + name)!, signature: URL(string: downloads + name + ".sig")!,
                                   size: Int64(archive.count))
        )
    }

    var phase: UpdateInstaller.Phase? { installer.installation?.phase }

    var failure: UpdateInstallError? {
        if case .failed(let error) = phase { error } else { nil }
    }

    func install(_ release: LatestRelease) async {
        installer.install(release)
        await installer.waitUntilDone()
    }

    private func serve(_ url: URL, to destination: URL, limit: Int64, progress: @Sendable (Int64) -> Void) async throws {
        let name = url.lastPathComponent
        downloads.append(name)
        if let error = failNextDownload {
            failNextDownload = nil
            throw error
        }
        if holdsArchive, name.hasSuffix(".zip") {
            try await Task.sleep(for: .seconds(60))
        }
        guard let data = files[name] else { throw UpdateInstallError.unavailable("HTTP status 404 for \(name)") }
        guard Int64(data.count) <= limit else { throw UpdateInstallError.unverified("\(data.count) bytes came for at most \(limit)") }
        progress(Int64(data.count / 2))
        progress(Int64(data.count))
        try data.write(to: destination, options: .withoutOverwriting)
    }

    private func isBusy() -> Bool {
        busyQuestions += 1
        return busyQuestions <= busyAnswers
    }

    private func restart(_ bundle: URL) throws {
        if let restartError { throw restartError }
        restarts.append(bundle)
    }

    func cleanUp() {
        removeFolder(folder)
    }
}

@MainActor
struct UpdateInstallerTests {
    @Test func anUpdateTakesTheAppsPlaceAndRestartsIt() async throws {
        let fixture = try await InstallFixture()
        defer { fixture.cleanUp() }
        let release = try await fixture.publish("1.2.0")
        #expect(fixture.installer.obstacle == nil)
        #expect(fixture.installer.canInstall(release))
        fixture.installer.install(release)
        #expect(fixture.phase == .downloading(received: 0, total: release.package!.size))
        await fixture.installer.waitUntilDone()
        #expect(fixture.phase == .restarting)
        #expect(fixture.restarts == [fixture.installed])
        #expect(versionOfApp(at: fixture.installed) == "1.2.0")
        #expect(fixture.downloads == ["Toolsy-1.2.0.zip.sig", "Toolsy-1.2.0.zip"], "the signature first: it bounds the archive")
        // A second click while the app restarts does nothing.
        fixture.installer.install(release)
        await fixture.installer.waitUntilDone()
        #expect(fixture.downloads.count == 2)
        #expect(fixture.restarts.count == 1)
        #expect(fixture.phase == .restarting)
    }

    @Test func nothingChangesUnlessTheReleaseKeySignedExactlyThisApp() async throws {
        let cases: [(String, (InstallFixture) async throws -> LatestRelease)] = [
            ("another key", { try await $0.publish("1.2.0", signer: Curve25519.Signing.PrivateKey()) }),
            ("changed after signing", { try await $0.publish("1.2.0", tamper: { $0[$0.count / 2] ^= 0xFF }) }),
            ("one byte more", { try await $0.publish("1.2.0", tamper: { $0.append(0) }) }),
            ("signed for another version", { try await $0.publish("1.2.0", signedVersion: "1.2.1") }),
            ("another version inside", { try await $0.publish("1.2.0", appVersion: "1.2.1") }),
            ("another app inside", { try await $0.publish("1.2.0", identifier: "com.example.other") }),
        ]
        for (name, publish) in cases {
            let fixture = try await InstallFixture()
            defer { fixture.cleanUp() }
            await fixture.install(try await publish(fixture))
            #expect(isUnverified(fixture.failure), "\(name): \(String(describing: fixture.phase))")
            #expect(fixture.failure?.isWorthRetrying == true)
            #expect(versionOfApp(at: fixture.installed) == "1.1.0", "\(name)")
            #expect(fixture.restarts.isEmpty, "\(name)")
        }
    }

    @Test func aFailedDownloadSaysWhyAndCanBeTriedAgain() async throws {
        let fixture = try await InstallFixture()
        defer { fixture.cleanUp() }
        let release = try await fixture.publish("1.2.0")
        fixture.failNextDownload = URLError(.notConnectedToInternet)
        await fixture.install(release)
        #expect(fixture.failure == .offline)
        fixture.failNextDownload = URLError(.badServerResponse)
        await fixture.install(release)
        if case .unavailable = fixture.failure {} else { Issue.record("\(String(describing: fixture.phase))") }
        fixture.files["Toolsy-1.2.0.zip"] = nil
        await fixture.install(release)
        if case .unavailable = fixture.failure {} else { Issue.record("a missing archive: \(String(describing: fixture.phase))") }
        fixture.installer.dismissFailure()
        #expect(fixture.installer.installation == nil)

        _ = try await fixture.publish("1.2.0")
        await fixture.install(release)
        #expect(fixture.phase == .restarting)
        #expect(versionOfApp(at: fixture.installed) == "1.2.0")
    }

    @Test func cancellingTheDownloadLeavesEverythingAsItWas() async throws {
        let fixture = try await InstallFixture()
        defer { fixture.cleanUp() }
        fixture.holdsArchive = true
        let release = try await fixture.publish("1.2.0")
        fixture.installer.install(release)
        while fixture.downloads.count < 2 {
            try await Task.sleep(for: .milliseconds(10))
        }
        fixture.installer.cancel()
        await fixture.installer.waitUntilDone()
        #expect(fixture.installer.installation == nil)
        #expect(versionOfApp(at: fixture.installed) == "1.1.0")
        #expect(fixture.restarts.isEmpty)
    }

    @Test func theAppIsReplacedOnlyOnceNothingIsInProgress() async throws {
        let fixture = try await InstallFixture()
        defer { fixture.cleanUp() }
        fixture.busyAnswers = 2
        await fixture.install(try await fixture.publish("1.2.0"))
        #expect(fixture.busyQuestions == 3)
        #expect(fixture.phase == .restarting)
        #expect(versionOfApp(at: fixture.installed) == "1.2.0")
    }

    @Test func anUpdateInPlaceThatCannotStartSaysSo() async throws {
        let fixture = try await InstallFixture()
        defer { fixture.cleanUp() }
        fixture.restartError = POSIXError(.EAGAIN)
        await fixture.install(try await fixture.publish("1.2.0"))
        #expect(fixture.failure == .notRestarted)
        #expect(fixture.failure?.isWorthRetrying == false)
        #expect(versionOfApp(at: fixture.installed) == "1.2.0", "the new version is in place for the next start")
    }

    @Test func anUpdateForANewerSystemIsNotInstalled() async throws {
        let fixture = try await InstallFixture()
        defer { fixture.cleanUp() }
        await fixture.install(try await fixture.publish("1.2.0", minimumSystem: "99.0"))
        #expect(fixture.failure == .needsNewerSystem(update: "1.2.0", system: "99.0"))
        #expect(versionOfApp(at: fixture.installed) == "1.1.0")
    }

    @Test func aCopyThatCannotInstallOnlyLinksToTheRelease() async throws {
        let fixture = try await InstallFixture()
        defer { fixture.cleanUp() }
        fixture.trusted = false
        let release = try await fixture.publish("1.2.0")
        #expect(fixture.installer.obstacle == .cannotReplace(.unsupportedBuild))
        #expect(!fixture.installer.canInstall(release))
        fixture.installer.install(release)
        #expect(fixture.installer.installation == nil)
        #expect(fixture.downloads.isEmpty)

        let byHand = LatestRelease(version: release.version, page: release.page, package: nil)
        let other = try await InstallFixture()
        defer { other.cleanUp() }
        #expect(!other.installer.canInstall(byHand), "a release without the files")
    }
}

// MARK: - Downloading

/// Answers the requests of a session configured with it from `answers`, by path.
private nonisolated final class StubbedGitHub: URLProtocol {
    struct Answer: Sendable {
        var status = 200
        var body = Data()
        /// The Content-Length sent; nil sends none.
        var declaredLength: Int?
    }

    static let answers = Mutex<[String: Answer]>([:])

    static func configuration() -> URLSessionConfiguration {
        let configuration = UpdateCheck.configuration()
        configuration.protocolClasses = [StubbedGitHub.self]
        return configuration
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let answer = Self.answers.withLock({ $0[url.path()] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
            return
        }
        let headers = answer.declaredLength.map { ["Content-Length": String($0)] } ?? [:]
        let response = HTTPURLResponse(url: url, statusCode: answer.status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        // In parts, as a network would.
        for start in stride(from: 0, to: answer.body.count, by: 1000) {
            client?.urlProtocol(self, didLoad: answer.body.subdata(in: start..<min(start + 1000, answer.body.count)))
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// The bytes a download reported, gathered from the session's queue.
private final class ProgressLog: Sendable {
    let reported = Mutex<[Int64]>([])
}

struct ReleaseDownloadTests {
    private func download(_ answer: StubbedGitHub.Answer, limit: Int64) async throws -> (file: Data, progress: [Int64]) {
        let path = "/sowhoia/toolsy/releases/download/v1.2.0/\(UUID().uuidString).zip"
        StubbedGitHub.answers.withLock { $0[path] = answer }
        let folder = try temporaryFolder()
        defer { removeFolder(folder) }
        let destination = folder.appending(path: "update.zip")
        let log = ProgressLog()
        try await ReleaseDownload.file(URL(string: "https://github.com\(path)")!, to: destination, limit: limit,
                                       configuration: StubbedGitHub.configuration()) { bytes in
            log.reported.withLock { $0.append(bytes) }
        }
        return (try Data(contentsOf: destination), log.reported.withLock { $0 })
    }

    @Test func aFileArrivesWithItsProgress() async throws {
        let body = Data((0..<4500).map { UInt8(truncatingIfNeeded: $0) })
        let (file, progress) = try await download(StubbedGitHub.Answer(body: body, declaredLength: body.count), limit: 4500)
        #expect(file == body)
        #expect(progress.last == 4500)
        #expect(progress == progress.sorted())
    }

    @Test func anAnswerThatIsNoFileIsAFailure() async throws {
        await #expect(throws: UpdateInstallError.self) {
            _ = try await self.download(StubbedGitHub.Answer(status: 404, body: Data("Not Found".utf8)), limit: 4500)
        }
    }

    @Test func moreThanTheLimitIsRefused() async throws {
        let body = Data(count: 6000)
        for declared in [6000, nil] as [Int?] {
            do {
                _ = try await download(StubbedGitHub.Answer(body: body, declaredLength: declared), limit: 4500)
                Issue.record("6000 bytes arrived for at most 4500 (declared \(String(describing: declared)))")
            } catch {
                #expect(isUnverified(error as? UpdateInstallError), "\(error)")
            }
        }
    }
}

// MARK: - Starting again

struct RelaunchArgumentsTests {
    @Test func theNewVersionStartsAsThisRunDidButOnItsFirstPage() {
        let options = LaunchOptions(arguments: ["Toolsy", "--open", "--page", "settings", "--appearance", "dark", "--keep-open",
                                                "--data-root", "/tmp/toolsy-data", "--simulate-helper"])
        let dataRoot = options.dataRoot?.path(percentEncoded: false) ?? ""
        #expect(options.relaunchArguments(openingPanel: false) == ["--keep-open", "--appearance", "dark", "--data-root", dataRoot, "--simulate-helper"])
        #expect(options.relaunchArguments(openingPanel: true).first == "--open")
        #expect(LaunchOptions(arguments: ["Toolsy"]).relaunchArguments(openingPanel: false).isEmpty)
    }
}
