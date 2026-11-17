import AppKit
import CryptoKit
import os
import Security
import ToolsyShared

nonisolated private let logger = Logger(subsystem: ToolsyPaths.bundleIdentifier, category: "updates")

/// Why an update was not installed.
nonisolated enum UpdateInstallError: Error, Equatable, Sendable {
    /// What keeps a copy of Toolsy from replacing itself.
    enum Obstacle: Equatable, Sendable {
        /// Not an app bundle, or a build without the release key.
        case unsupportedBuild
        /// macOS runs the app from a read-only copy until the user moves it out of the download (App Translocation).
        case translocated
        /// A disk that is read-only or cannot swap two folders in one step.
        case disk
        /// The user may not change the folder the app is in.
        case permission
    }

    /// The connection failed or dropped.
    case offline
    /// GitHub did not send the file; the detail is for the log.
    case unavailable(String)
    /// What arrived is not what the release key signed, or not this app; the detail is for the log.
    case unverified(String)
    case needsNewerSystem(update: String, system: String)
    /// The update has no code for this Mac's processor.
    case unsupportedMac(update: String)
    case cannotReplace(Obstacle)
    /// Unpacking or replacing failed; the detail is the system's reason.
    case failed(String)
    /// The update is in place, but the new version could not be started.
    case notRestarted

    var message: String {
        switch self {
        case .offline: String(localized: "The download stopped. Check the internet connection and try again.")
        case .unavailable: String(localized: "GitHub didn’t send the update. Try again later.")
        case .unverified: String(localized: "The downloaded file isn’t the update Toolsy’s developer signed. Nothing was changed.")
        case let .needsNewerSystem(update, system): String(localized: "Toolsy \(update) needs macOS \(system) or later.")
        case .unsupportedMac(let update): String(localized: "Toolsy \(update) doesn’t run on this Mac.")
        case .cannotReplace(.unsupportedBuild): String(localized: "This copy of Toolsy can’t update itself. Download the update instead.")
        case .cannotReplace(.translocated):
            String(localized: "macOS runs this copy of Toolsy from a temporary place. Move Toolsy to the Applications folder and open it from there to update it by itself.")
        case .cannotReplace(.disk): String(localized: "Toolsy can’t update itself on the disk it’s on. Move it to the Applications folder, or download the update.")
        case .cannotReplace(.permission):
            String(localized: "You can’t change the folder Toolsy is in. Download the update and replace Toolsy by hand.")
        case .failed(let reason): String(localized: "The update couldn’t be installed: \(reason)")
        case .notRestarted: String(localized: "Toolsy was updated but couldn’t restart. Quit Toolsy and open it again.")
        }
    }

    /// Whether trying again can help; otherwise only downloading the update from its page does.
    var isWorthRetrying: Bool {
        switch self {
        case .offline, .unavailable, .unverified, .failed: true
        case .needsNewerSystem, .unsupportedMac, .cannotReplace, .notRestarted: false
        }
    }
}

/// What Toolsy's release key vouches for, in `Toolsy-<version>.zip.sig` (written by `scripts/sign-update.swift`): the
/// archive of one version, by its size and SHA-256. The archive passes only as the version it was signed for.
nonisolated struct UpdateSignature: Equatable, Sendable {
    /// Far more than the JSON of a signature.
    static let maxFileSize: Int64 = 4096
    /// The Info.plist key with the public half of the release key, base64; `scripts/sign-update.swift` reads it too.
    static let infoKey = "ToolsyUpdatePublicKey"

    let version: ReleaseVersion
    let size: Int64
    /// Lowercase hex.
    let sha256: String

    /// The release key `bundle` trusts; nil for a build without one, which cannot install updates.
    static func trustedKey(in bundle: Bundle) -> Curve25519.Signing.PublicKey? {
        guard let text = bundle.object(forInfoDictionaryKey: infoKey) as? String else { return nil }
        guard let raw = Data(base64Encoded: text), let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else {
            logger.fault("\(infoKey, privacy: .public) in Info.plist is not an Ed25519 public key")
            return nil
        }
        return key
    }

    /// The bytes signed: the three facts under a label of their own, so that the signature vouches for nothing else.
    static func message(version: String, size: Int64, sha256: String) -> Data {
        Data("toolsy update signature 1\n\(version)\n\(size)\n\(sha256)".utf8)
    }

    private struct File: Decodable {
        var format: Int
        var version: String
        var size: Int64
        var sha256: String
        var signature: String
    }

    /// Reads a signature file and checks it with `key`.
    static func verify(_ file: Data, with key: Curve25519.Signing.PublicKey) throws(UpdateInstallError) -> UpdateSignature {
        guard file.count <= maxFileSize, let decoded = try? JSONDecoder().decode(File.self, from: file), decoded.format == 1,
              let version = ReleaseVersion(decoded.version), decoded.size > 0, isDigest(decoded.sha256),
              let signature = Data(base64Encoded: decoded.signature) else {
            throw .unverified("the signature file is not one this version of Toolsy can read")
        }
        guard key.isValidSignature(signature, for: message(version: decoded.version, size: decoded.size, sha256: decoded.sha256)) else {
            throw .unverified("the signature is not the release key's")
        }
        return UpdateSignature(version: version, size: decoded.size, sha256: decoded.sha256)
    }

    private static func isDigest(_ text: String) -> Bool {
        text.utf8.count == 64 && text.utf8.allSatisfy { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains($0) }
    }
}

/// The downloaded archive of an update.
nonisolated enum UpdateArchive {
    /// Checks that `archive` is the file `signature` names: its size, then its SHA-256.
    static func check(_ archive: URL, against signature: UpdateSignature) throws {
        let data = try Data(contentsOf: archive, options: .alwaysMapped)
        guard Int64(data.count) == signature.size else {
            throw UpdateInstallError.unverified("the archive has \(data.count) bytes, \(signature.size) were signed")
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == signature.sha256 else {
            throw UpdateInstallError.unverified("the archive's SHA-256 is \(digest), \(signature.sha256) was signed")
        }
    }

    /// Unpacks `archive` into `folder` as Finder would, except that nothing is marked as downloaded: the update is
    /// checked already, and Gatekeeper would stop a quarantined app that is not notarized when it starts.
    static func unpack(_ archive: URL, into folder: URL) async throws {
        let result = try await ProcessRunner.run(ProcessRunner.Request(
            executable: URL(filePath: "/usr/bin/ditto"),
            arguments: ["-x", "-k", "--noqtn", archive.path(percentEncoded: false), folder.path(percentEncoded: false)],
            timeout: 120
        ))
        guard result.succeeded else {
            let reason = String(decoding: result.stderr, as: UTF8.self).split(separator: "\n").last.map(String.init)
            throw UpdateInstallError.failed(reason ?? "ditto exited with status \(result.exitCode)")
        }
    }
}

/// The checks an unpacked update passes before it takes the running app's place.
nonisolated enum UpdateBundleCheck {
    struct Expectation: Sendable {
        /// The running app's bundle identifier.
        var identifier: String
        /// The version the release key signed.
        var version: ReleaseVersion
        /// The team that signed the running app, which must have signed the update too; nil for an ad hoc signature.
        var team: String?
    }

    /// The app the archive unpacked to in `folder`, if it is the update expected and runs on this Mac.
    static func app(in folder: URL, expecting expected: Expectation) throws -> URL {
        let entries = try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))
            .filter { $0 != "__MACOSX" && $0 != ".DS_Store" }
        guard entries.count == 1, entries[0].hasSuffix(".app") else {
            throw UpdateInstallError.unverified("the archive holds \(entries), not one app")
        }
        // Without a trailing slash, which would make lstat follow a link: a link would make the checks below read
        // another app than the one that is moved into place.
        let app = folder.appending(path: entries[0], directoryHint: .notDirectory)
        var info = stat()
        guard lstat(app.path(percentEncoded: false), &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              let bundle = Bundle(url: app), let plist = bundle.infoDictionary else {
            throw UpdateInstallError.unverified("\(entries[0]) is not an app bundle")
        }
        let identifier = plist["CFBundleIdentifier"] as? String
        guard identifier == expected.identifier else {
            throw UpdateInstallError.unverified("the app is \(identifier ?? "unnamed"), not \(expected.identifier)")
        }
        let version = plist["CFBundleShortVersionString"] as? String
        guard version.flatMap(ReleaseVersion.init) == expected.version else {
            throw UpdateInstallError.unverified("the app is version \(version ?? "none"), not \(expected.version)")
        }
        if let minimum = plist["LSMinimumSystemVersion"] as? String, let required = systemVersion(minimum),
           !ProcessInfo.processInfo.isOperatingSystemAtLeast(required) {
            throw UpdateInstallError.needsNewerSystem(update: expected.version.description, system: minimum)
        }
        guard let executable = bundle.executableURL, FileManager.default.isExecutableFile(atPath: executable.path(percentEncoded: false)) else {
            throw UpdateInstallError.unverified("the app has no executable")
        }
        guard bundle.executableArchitectures?.contains(NSNumber(value: runningArchitecture)) == true else {
            throw UpdateInstallError.unsupportedMac(update: expected.version.description)
        }
        try checkSignature(of: app, team: expected.team)
        return app
    }

    /// The architecture this process runs as, which the new version must be built for.
    private static var runningArchitecture: Int {
        #if arch(arm64)
        NSBundleExecutableArchitectureARM64
        #else
        NSBundleExecutableArchitectureX86_64
        #endif
    }

    /// "26.0" or "26.0.1"; nil for anything else, which leaves the check to LaunchServices.
    private static func systemVersion(_ text: String) -> OperatingSystemVersion? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard (1...3).contains(parts.count), parts.allSatisfy({ $0 != nil }) else { return nil }
        let numbers = parts.compactMap(\.self) + [0, 0]
        return OperatingSystemVersion(majorVersion: numbers[0], minorVersion: numbers[1], patchVersion: numbers[2])
    }

    /// The code signature seals every file of the app, for every architecture; with a team, the update must be signed
    /// with that team's Developer ID certificate.
    private static func checkSignature(of app: URL, team: String?) throws {
        var code: SecStaticCode?
        var status = SecStaticCodeCreateWithPath(app as CFURL, [], &code)
        guard status == errSecSuccess, let code else {
            throw UpdateInstallError.unverified("the app's code cannot be read: \(describe(status))")
        }
        var requirement: SecRequirement?
        if let team {
            status = SecRequirementCreateWithString("anchor apple generic and certificate leaf[subject.OU] = \"\(team)\"" as CFString, [], &requirement)
            guard status == errSecSuccess else {
                throw UpdateInstallError.failed("the requirement of team \(team) cannot be made: \(describe(status))")
            }
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        status = SecStaticCodeCheckValidityWithErrors(code, flags, requirement, nil)
        guard status == errSecSuccess else {
            throw UpdateInstallError.unverified("the app's code signature does not hold: \(describe(status))")
        }
    }

    private static func describe(_ status: OSStatus) -> String {
        SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
    }
}

/// Where the running copy of Toolsy is, and putting an update in its place.
nonisolated enum AppReplacement {
    /// What keeps `bundle` from being replaced by an update, or nil when nothing does.
    static func obstacle(for bundle: URL) -> UpdateInstallError.Obstacle? {
        guard bundle.pathExtension == "app" else { return .unsupportedBuild }
        if bundle.path(percentEncoded: false).contains("/AppTranslocation/") { return .translocated }
        do {
            let volume = try bundle.resourceValues(forKeys: [.volumeIsReadOnlyKey, .volumeSupportsSwapRenamingKey])
            if volume.volumeIsReadOnly == true || volume.volumeSupportsSwapRenaming == false { return .disk }
        } catch {
            // Replacing will fail with the reason then.
            logger.error("cannot tell what the volume of \(bundle.path(percentEncoded: false), privacy: .public) supports: \(error.localizedDescription, privacy: .public)")
        }
        // The update takes the app's place by renaming inside the folder that holds it.
        guard access(bundle.deletingLastPathComponent().path(percentEncoded: false), W_OK) == 0 else { return .permission }
        return nil
    }

    /// A new folder on the volume of `bundle`, so that an update unpacked there can swap places with it.
    static func stagingFolder(for bundle: URL) throws -> URL {
        try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: bundle, create: true)
    }

    /// Puts `update` where `installed` is in one step: the two swap places, so the replaced app is left where `update`
    /// was. Either is at `installed` at every moment.
    static func swap(_ update: URL, into installed: URL) throws {
        guard renamex_np(update.path(percentEncoded: false), installed.path(percentEncoded: false), UInt32(RENAME_SWAP)) == 0 else {
            throw UpdateInstallError.failed(String(cString: strerror(errno)))
        }
    }

    /// The team that signed the running app; nil for an ad hoc signature.
    static func runningTeam() -> String? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var information: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess
        else {
            // Without the running app's signature there is no team to hold the update to; the release key still is.
            logger.error("the running app's signature cannot be read; an update is checked by the release key alone")
            return nil
        }
        return (information as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// Opens `bundle` with `arguments` once process `pid` has exited. A shell of its own does it, in a session of its
    /// own so that it outlives this process; it gives up after two minutes.
    static func relaunch(_ bundle: URL, after pid: pid_t, arguments: [String]) throws {
        let script = """
            i=0
            while /bin/kill -0 "$1" 2>/dev/null && [ "$i" -lt 600 ]; do /bin/sleep 0.2; i=$((i + 1)); done
            app=$2
            shift 2
            if [ "$#" -gt 0 ]; then exec /usr/bin/open "$app" --args "$@"; fi
            exec /usr/bin/open "$app"
            """
        let words = ["/bin/sh", "-c", script, "toolsy-relaunch", String(pid), bundle.path(percentEncoded: false)] + arguments
        let environment = ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" }
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))
        var files: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&files)
        defer { posix_spawn_file_actions_destroy(&files) }
        for descriptor: Int32 in 0...2 {
            posix_spawn_file_actions_addopen(&files, descriptor, "/dev/null", descriptor == 0 ? O_RDONLY : O_WRONLY, 0)
        }
        let argv = words.map { strdup($0) } + [nil]
        let envp = environment.map { strdup($0) } + [nil]
        defer { (argv + envp).forEach { free($0) } }
        var child: pid_t = 0
        let status = posix_spawn(&child, "/bin/sh", &files, &attributes, argv, envp)
        guard status == 0 else { throw UpdateInstallError.failed(String(cString: strerror(status))) }
    }

    /// Removes a staging folder; one that stays behind is the system's to clear from the temporary items.
    static func remove(_ folder: URL) {
        do {
            try FileManager.default.removeItem(at: folder)
        } catch {
            logger.error("cannot remove \(folder.path(percentEncoded: false), privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// Installs a new version of Toolsy when the user asks: downloads the release's signature and archive, checks that the
/// release key signed exactly this archive and that it holds this app, in that version, for this Mac, waits until
/// nothing is in progress that a restart would break, swaps the new app into the running app's place in one step and
/// restarts Toolsy. Nothing is downloaded before the user asks, and nothing changes on disk until every check passed.
@Observable
final class UpdateInstaller {
    enum Phase: Equatable {
        /// `received` of `total` bytes of the archive have arrived.
        case downloading(received: Int64, total: Int64)
        /// Checking the update and putting it in place; Toolsy restarts at the end.
        case installing
        /// Toolsy is quitting, and the new version starts once it has.
        case restarting
        case failed(UpdateInstallError)
    }

    struct Installation: Equatable {
        let release: LatestRelease
        fileprivate(set) var phase: Phase
    }

    /// What the installer needs of the app; tests and debug runs give their own.
    struct Environment {
        /// The running app, which the update replaces.
        var bundle: URL
        var identifier: String
        var team: String?
        /// The public half of the release key; nil for a build without one, which cannot install updates.
        var trustedKey: Curve25519.Signing.PublicKey?
        /// Downloads a URL to a file that does not exist yet, refusing more than the limit and reporting the bytes
        /// received so far.
        var download: @Sendable (_ url: URL, _ destination: URL, _ limit: Int64,
                                 _ progress: @escaping @Sendable (Int64) -> Void) async throws -> Void
        /// Whether something is in progress that a restart would break: a dialog, a mod or the helper being installed.
        var isBusy: () -> Bool
        /// Starts the app at the URL once this process has exited, and quits.
        var restart: (URL) throws -> Void
    }

    /// The update under way, or the one that failed; nil while there is none.
    private(set) var installation: Installation?
    /// What keeps this copy of Toolsy from updating itself, so that updates are downloaded from their page instead.
    let obstacle: UpdateInstallError?

    @ObservationIgnored private let environment: Environment
    @ObservationIgnored private var task: Task<Void, Never>?

    init(environment: Environment) {
        self.environment = environment
        if environment.trustedKey == nil {
            obstacle = .cannotReplace(.unsupportedBuild)
        } else {
            obstacle = AppReplacement.obstacle(for: environment.bundle).map { .cannotReplace($0) }
        }
    }

    /// Whether `release` can be installed here; otherwise it is downloaded from its page.
    func canInstall(_ release: LatestRelease) -> Bool {
        release.package != nil && obstacle == nil
    }

    /// Downloads, checks and installs `release`, then restarts Toolsy. Does nothing while an update is under way, and
    /// once one is in place and Toolsy is restarting into it.
    func install(_ release: LatestRelease) {
        guard task == nil, installation?.phase != .restarting, let package = release.package, obstacle == nil else { return }
        installation = Installation(release: release, phase: .downloading(received: 0, total: package.size))
        task = Task {
            await run(release, package)
            task = nil
        }
    }

    /// Waits until the update under way has ended; for tests and scripted runs.
    func waitUntilDone() async {
        await task?.value
    }

    /// Stops the download; once the update is being checked or put in place, it runs to its end.
    func cancel() {
        guard case .downloading = installation?.phase else { return }
        task?.cancel()
    }

    /// Forgets an update that failed.
    func dismissFailure() {
        if case .failed = installation?.phase { installation = nil }
    }

    private func run(_ release: LatestRelease, _ package: UpdatePackage) async {
        let environment = environment
        let staging: URL
        do {
            staging = try AppReplacement.stagingFolder(for: environment.bundle)
        } catch {
            return finish(release, failing: .failed(error.localizedDescription))
        }
        defer { AppReplacement.remove(staging) }
        do {
            guard let key = environment.trustedKey else { throw UpdateInstallError.cannotReplace(.unsupportedBuild) }
            let signatureFile = staging.appending(path: "update.sig")
            try await environment.download(package.signature, signatureFile, UpdateSignature.maxFileSize) { _ in }
            let signature = try UpdateSignature.verify(try Data(contentsOf: signatureFile), with: key)
            guard signature.version == release.version else {
                throw UpdateInstallError.unverified("the archive is signed as \(signature.version), not \(release.version)")
            }

            let archive = staging.appending(path: "update.zip")
            setPhase(.downloading(received: 0, total: signature.size))
            try await environment.download(package.archive, archive, signature.size) { [weak self] received in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.show(received, of: signature.size) }
                }
            }
            try Task.checkCancellation()

            setPhase(.installing)
            let unpacked = staging.appending(path: "unpacked", directoryHint: .isDirectory)
            let expected = UpdateBundleCheck.Expectation(identifier: environment.identifier, version: release.version, team: environment.team)
            let app = try await Task.detached(priority: .userInitiated) {
                try UpdateArchive.check(archive, against: signature)
                try await UpdateArchive.unpack(archive, into: unpacked)
                return try UpdateBundleCheck.app(in: unpacked, expecting: expected)
            }.value

            // A restart now would cancel the dialog on screen or stop an installation halfway.
            while environment.isBusy() {
                try await Task.sleep(for: .milliseconds(250))
            }
            try AppReplacement.swap(app, into: environment.bundle)
        } catch {
            if Task.isCancelled {
                installation = nil
            } else {
                finish(release, failing: Self.installError(for: error))
            }
            return
        }
        // The replaced app is in the staging folder now, and goes with it before the quit this schedules: this process
        // keeps running on what it has loaded.
        logger.notice("Toolsy \(release.version.description, privacy: .public) is installed; restarting")
        setPhase(.restarting)
        do {
            try environment.restart(environment.bundle)
        } catch {
            logger.error("the new version could not be started: \(error.localizedDescription, privacy: .public)")
            setPhase(.failed(.notRestarted))
        }
    }

    private func setPhase(_ phase: Phase) {
        installation?.phase = phase
    }

    /// The bar moves by whole percents: the download reports many times a second.
    private func show(_ received: Int64, of total: Int64) {
        guard case .downloading(let shown, _) = installation?.phase, received > shown,
              received == total || (received - shown) * 100 >= total else { return }
        setPhase(.downloading(received: received, total: total))
    }

    private func finish(_ release: LatestRelease, failing error: UpdateInstallError) {
        logger.error("Toolsy \(release.version.description, privacy: .public) was not installed: \(String(describing: error), privacy: .public)")
        setPhase(.failed(error))
    }

    /// What an error of downloading, unpacking or replacing means for the user.
    static func installError(for error: any Error) -> UpdateInstallError {
        switch error {
        case let error as UpdateInstallError: return error
        case let error as URLError:
            switch UpdateCheck.error(for: error) {
            case .offline: return .offline
            case .rateLimited, .unexpected: return .unavailable(error.localizedDescription)
            }
        default: return .failed(error.localizedDescription)
        }
    }
}

extension UpdateInstaller.Environment {
    /// The running app, its release key and GitHub.
    static func running(isBusy: @escaping () -> Bool, restart: @escaping (URL) throws -> Void) -> Self {
        Self(
            bundle: Bundle.main.bundleURL,
            identifier: Bundle.main.bundleIdentifier ?? "",
            team: AppReplacement.runningTeam(),
            trustedKey: UpdateSignature.trustedKey(in: Bundle.main),
            download: { url, destination, limit, progress in
                try await ReleaseDownload.file(url, to: destination, limit: limit, progress: progress)
            },
            isBusy: isBusy,
            restart: restart
        )
    }
}
