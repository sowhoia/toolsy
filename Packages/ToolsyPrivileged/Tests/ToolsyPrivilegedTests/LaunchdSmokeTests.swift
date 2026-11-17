import Foundation
import Testing
@testable import ToolsyHelperClient
import ToolsyHelperXPC
import ToolsyShared

/// The real daemon code (a test build with a test configuration) started on demand by launchd in the
/// current user's GUI domain under a unique label, with the real client connecting to its Mach service.
/// Never touches the system domain or the real label.
@Suite struct LaunchdSmokeTests {
    private let uid = getuid()
    private let label = "app.toolsy.tests.helper-\(UUID().uuidString.lowercased())"
    private var service: String { "gui/\(uid)/\(label)" }

    @discardableResult
    private func launchctl(_ arguments: String...) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/launchctl")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, text(data))
    }

    private func isRunning() throws -> Bool {
        try launchctl("print", service).output.contains("state = running")
    }

    private func writeJob(plist: URL, daemon: URL, store: URL, log: URL) throws {
        let job: [String: Any] = [
            "Label": label,
            "MachServices": [label: true],
            "ProgramArguments": [daemon.path(percentEncoded: false), store.path(percentEncoded: false), label, plist.path(percentEncoded: false)],
            "StandardErrorPath": log.path(percentEncoded: false),
        ]
        try PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0).write(to: plist)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: plist.path(percentEncoded: false))
    }

    private func prepareStore(_ store: URL, requirement: String, user: uid_t = getuid()) throws {
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        for (name, contents) in [(HelperConstants.clientRequirementFileName, requirement), (HelperConstants.clientUserFileName, "\(user)")] {
            let file = store.appending(path: name)
            try Data(contents.utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path(percentEncoded: false))
        }
    }

    @Test func daemonServesTheClientThroughLaunchd() async throws {
        #expect(label != HelperConstants.label)
        let daemon = productsDirectory.appending(path: "ToolsyHelperTestDaemon")
        #expect(FileManager.default.isExecutableFile(atPath: daemon.path(percentEncoded: false)), "build the test daemon first")
        let directory = try TemporaryDirectory()
        let store = directory.path("store")
        let plist = directory.path("\(label).plist")
        let log = directory.path("daemon.log")
        defer { _ = try? launchctl("bootout", service) }

        try prepareStore(store, requirement: try ownRequirement())
        try writeJob(plist: plist, daemon: daemon, store: store, log: log)
        let bootstrap = try launchctl("bootstrap", "gui/\(uid)", plist.path(percentEncoded: false))
        try #require(bootstrap.status == 0, "\(bootstrap.output)")

        let label = label
        let client = HelperClient(configuration: HelperClient.Configuration(
            installedHelper: daemon, launchdPlist: plist, bundledHelper: daemon,
            connect: { NSXPCConnection(machServiceName: label, options: []) },
            installLayout: .production,
            runAsAdministrator: { _ in Issue.record("unexpected administrator prompt") },
            timeouts: HelperClient.Timeouts()
        ))

        #expect(await client.status() == .ready, "\((try? String(contentsOf: log, encoding: .utf8)) ?? "")")
        let payload = try ProbeMod.payload()
        try await client.approve(modID: ProbeMod.id, payload: payload)
        let output = keyValues(try await client.run(modID: ProbeMod.id, command: "env", input: ProbeMod.input("env")).stdout)
        #expect(output["TOOLSY_MOD_DIR"] == store.appending(path: "Mods/\(ProbeMod.id)").path(percentEncoded: false))
        #expect(output["HOME"] == "/var/root")

        // Idle for its 2-second interval, the daemon exits; the next call starts it again.
        #expect(try await eventually(within: .seconds(10)) { (try? isRunning()) == false })
        #expect(try await client.approvedMods() == [ProbeMod.id: payload.digest])
        #expect(try isRunning())

        try await client.uninstall()
        #expect(!FileManager.default.fileExists(atPath: store.path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: plist.path(percentEncoded: false)))
        #expect(try await eventually(within: .seconds(10)) { (try? launchctl("print", service).status) != 0 })
        #expect(await client.status() == .notInstalled)

        // A helper authorised for another build rejects this process across processes too.
        try prepareStore(store, requirement: requirement(cdhash: String(repeating: "0", count: 40)))
        try writeJob(plist: plist, daemon: daemon, store: store, log: log)
        try #require(try launchctl("bootstrap", "gui/\(uid)", plist.path(percentEncoded: false)).status == 0)
        let started = ContinuousClock.now
        #expect(await client.status() == .needsUpdate)
        #expect(ContinuousClock.now - started < .seconds(4))
        try launchctl("bootout", service)

        // So does one installed by another user, although this is the right build.
        try prepareStore(store, requirement: try ownRequirement(), user: uid + 1)
        try #require(try launchctl("bootstrap", "gui/\(uid)", plist.path(percentEncoded: false)).status == 0)
        #expect(await client.status() == .needsUpdate)
        try launchctl("bootout", service)

        // Without a client requirement the daemon exits instead of serving anyone.
        try FileManager.default.removeItem(at: store.appending(path: HelperConstants.clientRequirementFileName))
        try #require(try launchctl("bootstrap", "gui/\(uid)", plist.path(percentEncoded: false)).status == 0)
        #expect(await client.status() == .needsUpdate)
        #expect(try launchctl("print", service).output.contains("last exit code = 1"))
    }

    /// The installed daemon's memory reclaim, through launchd, runs the real system tools. As the
    /// current user they are refused by the kernel, so this proves the wiring and changes nothing.
    @Test func daemonReclaimsMemoryWithTheSystemTools() async throws {
        let daemon = productsDirectory.appending(path: "ToolsyHelperTestDaemon")
        let directory = try TemporaryDirectory()
        let store = directory.path("store")
        let plist = directory.path("\(label).plist")
        let log = directory.path("daemon.log")
        defer { _ = try? launchctl("bootout", service) }
        try prepareStore(store, requirement: try ownRequirement())
        try writeJob(plist: plist, daemon: daemon, store: store, log: log)
        try #require(try launchctl("bootstrap", "gui/\(uid)", plist.path(percentEncoded: false)).status == 0)

        let label = label
        let client = HelperClient(configuration: HelperClient.Configuration(
            installedHelper: daemon, launchdPlist: plist, bundledHelper: daemon,
            connect: { NSXPCConnection(machServiceName: label, options: []) },
            installLayout: .production,
            runAsAdministrator: { _ in Issue.record("unexpected administrator prompt") },
            timeouts: HelperClient.Timeouts()
        ))
        let started = ContinuousClock.now
        #expect(try await client.reclaimMemory() == MemoryReclaimReport(diskCacheFlushed: false, pressureWarningSent: false))
        #expect(ContinuousClock.now - started < .seconds(10))
    }

    @Test func productionHelperRefusesToRunAsAUser() throws {
        let process = Process()
        process.executableURL = productsDirectory.appending(path: "ToolsyHelper")
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == EXIT_FAILURE)
    }
}
