import Foundation
import Testing
@testable import ToolsyHelperClient
@testable import ToolsyHelperCore
import ToolsyHelperXPC
import ToolsyShared

private let validHash = "0123456789abcdef0123456789abcdef01234567"

/// A scratch root for the installer with `launchctl` and `chown` replaced by stubs that log their arguments.
private final class ScratchInstall {
    let directory: TemporaryDirectory
    let layout: InstallLayout
    let bundledHelper: URL
    let log: URL

    init(launchctlFailures: Int = 0) throws {
        directory = try TemporaryDirectory()
        log = directory.path("calls.log")
        let counter = directory.path("bootstrap-failures")
        try Data("\(launchctlFailures)".utf8).write(to: counter)
        let launchctl = try directory.write("""
            #!/bin/sh
            echo "launchctl $*" >> \(InstallScript.shellQuoted(log.path(percentEncoded: false)))
            if [ "$1" = bootstrap ]; then
                left=$(cat \(InstallScript.shellQuoted(counter.path(percentEncoded: false))))
                if [ "$left" -gt 0 ]; then
                    echo $((left - 1)) > \(InstallScript.shellQuoted(counter.path(percentEncoded: false)))
                    echo "Bootstrap failed: 5: Input/output error" >&2
                    exit 5
                fi
            fi
            """, to: "bin/launchctl")
        let chown = try directory.write("""
            #!/bin/sh
            echo "chown $*" >> \(InstallScript.shellQuoted(log.path(percentEncoded: false)))
            """, to: "bin/chown")
        for stub in [launchctl, chown] {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path(percentEncoded: false))
        }
        // Spaces and both kinds of quotes in the app's path must survive quoting.
        bundledHelper = try directory.write("#!/bin/sh\necho helper\n", to: "Apps/Toolsy's \"Test\" App.app/Contents/Helpers/ToolsyHelper")
        let root = directory.url.path(percentEncoded: false)
        layout = InstallLayout(
            helper: root + "/Library/PrivilegedHelperTools/app.toolsy.helper",
            plist: root + "/Library/LaunchDaemons/app.toolsy.helper.plist",
            store: root + "/Library/Application Support/Toolsy",
            label: HelperConstants.label,
            bundleIdentifier: ToolsyPaths.bundleIdentifier,
            domain: "system",
            launchctl: launchctl.path(percentEncoded: false),
            chown: chown.path(percentEncoded: false)
        )
        try FileManager.default.createDirectory(atPath: root + "/Library/Application Support", withIntermediateDirectories: true)
    }

    func installCommand(cdhash: String = validHash, clientUID: uid_t = 501) throws -> String {
        try InstallScript.installCommand(layout: layout, bundledHelper: bundledHelper, cdhash: cdhash, clientUID: clientUID)
    }

    var calls: [String] {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    /// Every file under the scratch Library with its mode and contents.
    func snapshot() throws -> [String: String] {
        let library = directory.path("Library")
        var result: [String: String] = [:]
        let enumerator = try #require(FileManager.default.enumerator(atPath: library.path(percentEncoded: false)))
        while let relative = enumerator.nextObject() as? String {
            let url = library.appending(path: relative)
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory)
            let contents = isDirectory.boolValue ? "<dir>" : text(try Data(contentsOf: url))
            result[relative] = String(try mode(of: url), radix: 8) + " " + contents
        }
        return result
    }
}

/// Runs a shell command line the way `do shell script` does.
private func shell(_ command: String) throws -> (status: Int32, stderr: String) {
    let process = Process()
    process.executableURL = URL(filePath: "/bin/sh")
    process.arguments = ["-c", command]
    let errors = Pipe()
    process.standardError = errors
    try process.run()
    let stderr = errors.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, text(stderr))
}

/// Loads AppleScript's scripting additions from the main thread.
///
/// The first script a process runs loads them. In the app, whose main thread runs AppKit's event loop, that
/// takes milliseconds on any thread. The test runner's main thread only drains a run loop, and there the
/// first script started on another thread waits for an event nothing services: half a minute alone, ten
/// minutes when the whole suite runs. Loading the additions here first puts the process in the app's state.
@MainActor private func loadScriptingAdditions() {
    _ = NSAppleScript(source: "do shell script \"true\"")?.executeAndReturnError(nil)
}

@Suite struct InstallerTests {
    @Test func productionCommandIsTheFixedScriptWithQuotedInputs() throws {
        let helper = URL(filePath: "/Applications/Toolsy's \"Best\" App.app/Contents/Helpers/ToolsyHelper")
        let command = try InstallScript.installCommand(layout: .production, bundledHelper: helper, cdhash: validHash, clientUID: 501)
        #expect(command.hasPrefix("/bin/sh -c '"))
        #expect(command.hasSuffix(#" toolsy-installer '/Applications/Toolsy'\''s "Best" App.app/Contents/Helpers/ToolsyHelper' '\#(validHash)' '501'"#))
        for assignment in [
            "helper='/Library/PrivilegedHelperTools/app.toolsy.helper'",
            "plist='/Library/LaunchDaemons/app.toolsy.helper.plist'",
            "store='/Library/Application Support/Toolsy'",
            "label='app.toolsy.helper'", "bundle_id='app.toolsy'", "domain='system'",
            "launchctl='/bin/launchctl'", "chown='/usr/sbin/chown'",
        ] {
            #expect(command.contains(assignment.replacing("'", with: #"'\''"#)), "\(assignment)")
        }
        // The tested scratch command carries the very same body.
        let quotedBody = InstallScript.installBody.replacing("'", with: #"'\''"#)
        #expect(command.contains(quotedBody))
        #expect(try ScratchInstall().installCommand().contains(quotedBody))
    }

    @Test func shellQuotingPreservesEveryCharacter() throws {
        for value in ["plain", "with space", "it's", #"a "b" c"#, "$(touch /tmp/x) `id` \\ ; | &", "'"] {
            let output = Pipe()
            let process = Process()
            process.executableURL = URL(filePath: "/bin/sh")
            process.arguments = ["-c", "printf %s " + InstallScript.shellQuoted(value)]
            process.standardOutput = output
            try process.run()
            process.waitUntilExit()
            #expect(text(output.fileHandleForReading.readDataToEndOfFile()) == value)
        }
    }

    @Test func refusesMalformedInputs() throws {
        let helper = URL(filePath: "/Applications/Toolsy.app/Contents/Helpers/ToolsyHelper")
        for hash in ["", String(validHash.dropLast()), validHash + "0", validHash.uppercased(), "$(id)" + validHash.dropFirst(5), validHash.dropLast() + "'"] {
            #expect(throws: PrivilegedError.self, "\(hash)") {
                try InstallScript.installCommand(layout: .production, bundledHelper: helper, cdhash: hash, clientUID: 501)
            }
        }
        #expect(throws: PrivilegedError.self) {
            try InstallScript.installCommand(layout: .production, bundledHelper: URL(filePath: "/Apps/a\nb/ToolsyHelper"), cdhash: validHash, clientUID: 501)
        }
        var layout = InstallLayout.production
        layout.label = "a<b"
        #expect(throws: PrivilegedError.self) {
            try InstallScript.installCommand(layout: layout, bundledHelper: helper, cdhash: validHash, clientUID: 501)
        }
    }

    @Test func installsIntoAScratchRootAndIsIdempotent() throws {
        let scratch = try ScratchInstall()
        let first = try shell(scratch.installCommand())
        #expect(first.status == 0, "\(first.stderr)")
        let installed = try scratch.snapshot()

        let library = "Library/"
        let helper = String(scratch.layout.helper.dropFirst(scratch.directory.url.path(percentEncoded: false).count + 1 + library.count))
        let plist = String(scratch.layout.plist.dropFirst(scratch.directory.url.path(percentEncoded: false).count + 1 + library.count))
        #expect(installed[helper] == "755 #!/bin/sh\necho helper\n")
        #expect(installed["Application Support/Toolsy"] == "755 <dir>")
        #expect(installed["Application Support/Toolsy/client-requirement"] == "644 cdhash H\"\(validHash)\"")
        #expect(installed["Application Support/Toolsy/client-user"] == "644 501")
        #expect(installed[plist]?.hasPrefix("644 ") == true)
        #expect(Set(installed.keys) == [
            "PrivilegedHelperTools", helper, "LaunchDaemons", plist, "Application Support",
            "Application Support/Toolsy", "Application Support/Toolsy/client-requirement", "Application Support/Toolsy/client-user",
        ])

        let property = try PropertyListSerialization.propertyList(from: Data(contentsOf: URL(filePath: scratch.layout.plist)), format: nil)
        let job = try #require(property as? [String: Any])
        #expect(Set(job.keys) == ["Label", "MachServices", "ProgramArguments", "AssociatedBundleIdentifiers"])
        #expect(job["Label"] as? String == HelperConstants.label)
        #expect(job["MachServices"] as? [String: Bool] == [HelperConstants.label: true])
        #expect(job["ProgramArguments"] as? [String] == [scratch.layout.helper])
        #expect(job["AssociatedBundleIdentifiers"] as? [String] == ["app.toolsy"])

        let store = scratch.layout.store
        let expectedCalls = [
            "chown root:wheel \(scratch.layout.helper).new",
            "chown root:wheel \(store)",
            "chown root:wheel \(store)/client-requirement.new",
            "chown root:wheel \(store)/client-user.new",
            "chown root:wheel \(scratch.layout.plist).new",
            "launchctl bootout system/app.toolsy.helper",
            "launchctl bootstrap system \(scratch.layout.plist)",
        ]
        #expect(scratch.calls == expectedCalls)

        let second = try shell(scratch.installCommand())
        #expect(second.status == 0, "\(second.stderr)")
        #expect(try scratch.snapshot() == installed)
        #expect(scratch.calls == expectedCalls + expectedCalls)
    }

    @Test func updatesARunningInstallation() throws {
        let scratch = try ScratchInstall()
        #expect(try shell(scratch.installCommand()).status == 0)
        try Data("#!/bin/sh\necho newer\n".utf8).write(to: scratch.bundledHelper)
        let otherHash = String(repeating: "f", count: 40)
        #expect(try shell(scratch.installCommand(cdhash: otherHash)).status == 0)
        #expect(try String(contentsOfFile: scratch.layout.helper, encoding: .utf8) == "#!/bin/sh\necho newer\n")
        #expect(try String(contentsOfFile: scratch.layout.store + "/client-requirement", encoding: .utf8) == "cdhash H\"\(otherHash)\"")
        // Another administrator takes the helper over; it then works for them.
        #expect(try shell(scratch.installCommand(cdhash: otherHash, clientUID: 502)).status == 0)
        #expect(try String(contentsOfFile: scratch.layout.store + "/client-user", encoding: .utf8) == "502")
    }

    @Test func retriesABootstrapThatFailsWhileTheOldJobIsGoing() throws {
        let scratch = try ScratchInstall(launchctlFailures: 1)
        let result = try shell(scratch.installCommand())
        #expect(result.status == 0, "\(result.stderr)")
        #expect(scratch.calls.filter { $0.hasPrefix("launchctl bootstrap") }.count == 2)
    }

    @Test func theScriptChecksTheHashItself() throws {
        let scratch = try ScratchInstall()
        let command = try scratch.installCommand()
        let forged = command.replacing("'\(validHash)'", with: "'\(validHash.dropLast())g'")
        let result = try shell(forged)
        #expect(result.status == 64)
        #expect(result.stderr == "invalid code hash\n")
        #expect(!FileManager.default.fileExists(atPath: scratch.layout.helper))
    }

    @Test func removalDeletesEverythingTheInstallerCreated() throws {
        let scratch = try ScratchInstall()
        #expect(try shell(scratch.installCommand()).status == 0)
        let removal = try shell(InstallScript.removalCommand(layout: scratch.layout))
        #expect(removal.status == 0, "\(removal.stderr)")
        #expect(try scratch.snapshot() == ["PrivilegedHelperTools": "755 <dir>", "LaunchDaemons": "755 <dir>", "Application Support": "755 <dir>"])
        #expect(scratch.calls.last == "launchctl bootout system/app.toolsy.helper")
        // Removing again is harmless.
        #expect(try shell(InstallScript.removalCommand(layout: scratch.layout)).status == 0)
    }

    @Test func theSameCommandSurvivesAppleScriptQuoting() async throws {
        await loadScriptingAdditions()
        let scratch = try ScratchInstall()
        let source = AdministratorPrompt.appleScript(running: try scratch.installCommand(), withAdministratorPrivileges: false)
        try await AdministratorPrompt.execute(source)
        #expect(try String(contentsOfFile: scratch.layout.store + "/client-requirement", encoding: .utf8) == "cdhash H\"\(validHash)\"")
        #expect(scratch.calls.count == 7)
        #expect(AdministratorPrompt.appleScript(running: "x", withAdministratorPrivileges: true) == #"tell current application to do shell script "x" with administrator privileges"#)
    }

    @Test func mapsAppleScriptFailures() async throws {
        await loadScriptingAdditions()
        await #expect(throws: PrivilegedError.cancelled) {
            try await AdministratorPrompt.execute("error number -128")
        }
        let error = await #expect(throws: PrivilegedError.self) {
            try await AdministratorPrompt.execute(AdministratorPrompt.appleScript(running: "echo boom >&2; exit 3", withAdministratorPrivileges: false))
        }
        #expect(error?.localizedDescription.contains("boom") == true)
    }

    @Test func installRunsTheScriptAndWaitsForTheNewHelper() async throws {
        let scratch = try ScratchInstall()
        let listener = ListenerBox()
        let endpoint = listener.listener.endpoint
        let served = Locked<HelperServer?>(nil)
        let layout = scratch.layout
        let client = HelperClient(configuration: HelperClient.Configuration(
            installedHelper: URL(filePath: layout.helper),
            launchdPlist: URL(filePath: layout.plist),
            bundledHelper: scratch.bundledHelper,
            connect: { NSXPCConnection(listenerEndpoint: endpoint) },
            installLayout: layout,
            runAsAdministrator: { command in
                let result = try shell(command)
                guard result.status == 0 else { throw PrivilegedError.rejected(result.stderr) }
                // What launchd does after bootstrap: start the helper from what the script installed.
                let store = try ModStore(root: URL(filePath: layout.store, directoryHint: .isDirectory), ownerUID: getuid())
                let server = HelperServer(
                    service: HelperService(store: store, installedFiles: []),
                    clientUID: try ClientUser.load(from: store.clientUser, ownerUID: getuid()), idleInterval: 3600,
                    removeLaunchdJob: {}, exitProcess: {}
                )
                server.serve(on: listener.listener, clientRequirement: try ClientRequirement.load(from: store.clientRequirement, ownerUID: getuid()))
                served.withLock { $0 = server }
            },
            timeouts: HelperClient.Timeouts()
        ))
        #expect(await client.status() == .notInstalled)
        try await client.install()
        #expect(await client.status() == .ready)
        let requirementText = try String(contentsOfFile: layout.store + "/client-requirement", encoding: .utf8)
        #expect(requirementText == (try ownRequirement()))
    }

    @Test func installFailsWhenTheHelperNeverAnswers() async throws {
        let fake = try FakeHelper(SilentHelper())
        var configuration = fake.client(timeouts: .short).configuration
        configuration.runAsAdministrator = { _ in }
        let started = ContinuousClock.now
        await #expect(throws: PrivilegedError.self) { try await HelperClient(configuration: configuration).install() }
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test func ownCodeHashMatchesCodesign() throws {
        let hash = try CodeIdentity.currentCDHash()
        #expect(hash.wholeMatch(of: /[0-9a-f]{40}/) != nil)
        // codesign reports the same hash for the process's main executable.
        let executable = try #require(Bundle.main.executableURL)
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/codesign")
        process.arguments = ["-dvvv", executable.path(percentEncoded: false)]
        let output = Pipe()
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        #expect(text(output.fileHandleForReading.readDataToEndOfFile()).contains("CDHash=\(hash)\n"))
    }
}

@Suite struct StatusTests {
    private func client(installed: String?, bundled: String, plist: Bool, in directory: TemporaryDirectory) throws -> HelperClient {
        let installedURL = directory.path("installed")
        if let installed { try directory.write(installed, to: "installed") }
        let bundledURL = try directory.write(bundled, to: "bundled")
        let plistURL = directory.path("job.plist")
        if plist { try directory.write("plist", to: "job.plist") }
        return HelperClient(configuration: HelperClient.Configuration(
            installedHelper: installedURL, launchdPlist: plistURL, bundledHelper: bundledURL,
            connect: {
                Issue.record("status must not connect before the files check out")
                return NSXPCConnection(machServiceName: "app.toolsy.tests.unused", options: [])
            },
            installLayout: .production,
            runAsAdministrator: { _ in Issue.record("unexpected administrator prompt") },
            timeouts: .short
        ))
    }

    @Test func missingFilesMeanNotInstalled() async throws {
        let directory = try TemporaryDirectory()
        #expect(try await client(installed: nil, bundled: "v1", plist: true, in: directory).status() == .notInstalled)
        let other = try TemporaryDirectory()
        #expect(try await client(installed: "v1", bundled: "v1", plist: false, in: other).status() == .notInstalled)
    }

    @Test func aDifferentBinaryNeedsAnUpdate() async throws {
        let directory = try TemporaryDirectory()
        #expect(try await client(installed: "v1", bundled: "v2", plist: true, in: directory).status() == .needsUpdate)
    }

    @Test func aMatchingBinaryThatAnswersIsReady() async throws {
        let fake = try FakeHelper(SilentHelper(version: HelperConstants.protocolVersion))
        #expect(await fake.client(timeouts: .short).status() == .ready)
    }

    @Test func uninstallFallsBackToTheAdministratorScriptWhenTheHelperIsGone() async throws {
        let fake = try FakeHelper(HangingUpHelper())
        let commands = Locked<[String]>([])
        var configuration = fake.client(timeouts: .short).configuration
        configuration.runAsAdministrator = { command in commands.withLock { $0.append(command) } }
        try await HelperClient(configuration: configuration).uninstall()
        #expect(commands.withLock { $0 } == [try InstallScript.removalCommand(layout: .production)])

        // Nothing left to remove: no prompt.
        try FileManager.default.removeItem(at: fake.plist)
        try FileManager.default.removeItem(at: fake.installedHelper)
        var layout = InstallLayout.production
        layout.store = fake.directory.path("no-store").path(percentEncoded: false)
        configuration.installLayout = layout
        try await HelperClient(configuration: configuration).uninstall()
        #expect(commands.withLock { $0.count } == 1)
    }
}

/// Hands an anonymous listener to the stand-in for launchd.
// @unchecked: NSXPCListener is not marked Sendable; the closure that captures it resumes it once.
private final class ListenerBox: @unchecked Sendable {
    let listener = NSXPCListener.anonymous()
}
