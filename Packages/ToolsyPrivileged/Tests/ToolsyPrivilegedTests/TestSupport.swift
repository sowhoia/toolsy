import Foundation
import Synchronization
import Testing
@testable import ToolsyHelperClient
@testable import ToolsyHelperCore
import ToolsyHelperXPC
import ToolsyShared

/// A scratch directory removed when the test ends.
final class TemporaryDirectory {
    let url: URL

    init() throws {
        url = URL.temporaryDirectory.appending(path: "toolsy-privileged-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    func path(_ relative: String) -> URL {
        url.appending(path: relative)
    }

    @discardableResult
    func write(_ contents: String, to relativePath: String) throws -> URL {
        let file = url.appending(path: relativePath)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: file)
        return file
    }
}

func text(_ data: Data) -> String {
    String(decoding: data, as: UTF8.self)
}

/// `key=value` lines as a dictionary.
func keyValues(_ data: Data) -> [String: String] {
    var result: [String: String] = [:]
    for line in text(data).split(separator: "\n") {
        guard let equals = line.firstIndex(of: "=") else { continue }
        result[String(line[..<equals])] = String(line[line.index(after: equals)...])
    }
    return result
}

/// The canonical path, as `pwd -P` prints it (Foundation's resolving drops `/private`).
func realPath(_ url: URL) -> String? {
    guard let resolved = realpath(url.path(percentEncoded: false), nil) else { return nil }
    defer { free(resolved) }
    return String(cString: resolved)
}

/// The directory holding the built products, next to the test bundle.
var productsDirectory: URL {
    Bundle(for: FakeHelper.self).bundleURL.deletingLastPathComponent()
}

func mode(of url: URL) throws -> Int {
    try #require(FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))[.posixPermissions] as? Int)
}

func owner(of url: URL) throws -> UInt32 {
    try #require((FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))[.ownerAccountID] as? NSNumber)?.uint32Value)
}

/// Polls `condition` until it holds or `timeout` passes.
func eventually(within timeout: Duration = .seconds(5), _ condition: () -> Bool) async throws -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

/// A privileged mod exercising everything the helper does with a command.
enum ProbeMod {
    static let id = "probe"

    static func manifest(id: String = ProbeMod.id, version: String = "1") -> String {
        """
        {
          "schema": 1, "id": "\(id)", "name": "Probe", "version": "\(version)",
          "commands": {
            "env": { "exec": "bin/probe.sh", "args": ["one arg"], "privileged": true },
            "echo": { "shell": "cat", "privileged": true, "stdin": true },
            "nostdin": { "shell": "wc -c | tr -d ' '", "privileged": true },
            "slow": { "shell": "echo $$ > \\"$TOOLSY_DATA_DIR/pid\\"; sleep 30", "privileged": true, "timeout": 0.5 },
            "settle": { "shell": "touch \\"$TOOLSY_DATA_DIR/started\\"; sleep 1; touch \\"$TOOLSY_DATA_DIR/finished\\"", "privileged": true },
            "plain": { "shell": "echo hi" }
          }
        }
        """
    }

    static let probeScript = """
        #!/bin/sh
        printf 'version=%s\\n' "\(versionMarker)"
        printf 'self=%s\\n' "$0"
        printf 'file=%s\\n' "$(cat version.txt)"
        printf 'pwd=%s\\n' "$(/bin/pwd -P)"
        printf 'arg=%s\\n' "$1"
        printf 'HOME=%s\\n' "$HOME"
        printf 'USER=%s\\n' "$USER"
        printf 'PATH=%s\\n' "$PATH"
        printf 'TMPDIR=%s\\n' "${TMPDIR-unset}"
        printf 'TOOLSY_MOD_ID=%s\\n' "$TOOLSY_MOD_ID"
        printf 'TOOLSY_MOD_DIR=%s\\n' "$TOOLSY_MOD_DIR"
        printf 'TOOLSY_DATA_DIR=%s\\n' "$TOOLSY_DATA_DIR"
        printf 'TOOLSY_EVENT=%s\\n' "$TOOLSY_EVENT"
        printf 'TOOLSY_COMMAND=%s\\n' "$TOOLSY_COMMAND"
        printf 'TOOLSY_KEY=%s\\n' "$TOOLSY_KEY"
        printf 'TOOLSY_VALUE=%s\\n' "$TOOLSY_VALUE"
        printf 'TOOLSY_STATE_level=%s\\n' "$TOOLSY_STATE_level"
        printf 'stdin=%s\\n' "$(cat)"
        """
    static let versionMarker = "@VERSION@"

    static func files(id: String = ProbeMod.id, version: String = "1", extra: [String: String] = [:]) -> [String: Data] {
        var files = [
            ModManifest.fileName: Data(manifest(id: id, version: version).utf8),
            "bin/probe.sh": Data(probeScript.replacing(versionMarker, with: version).utf8),
            "docs/readme.txt": Data("notes".utf8),
            "version.txt": Data(version.utf8),
        ]
        for (path, contents) in extra { files[path] = Data(contents.utf8) }
        return files
    }

    static let executables = ["bin/probe.sh"]

    static func payload(id: String = ProbeMod.id, version: String = "1", extra: [String: String] = [:]) throws -> ModPayload {
        try ModPayload(files: files(id: id, version: version, extra: extra), executables: Set(executables))
    }

    static func input(_ command: String, key: String? = nil, value: JSONValue? = nil) -> CommandInput {
        CommandInput(event: .command, command: command, key: key, value: value, state: ["level": 7, "host": "example.com"])
    }

    static func encoded(_ input: CommandInput) throws -> Data {
        try JSONEncoder().encode(input)
    }
}

func makeStore(in directory: TemporaryDirectory) throws -> ModStore {
    let root = directory.path("store")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return try ModStore(root: root, ownerUID: getuid())
}

func requirement(cdhash: String) -> String {
    "cdhash H\"\(cdhash)\""
}

/// The real helper server on an anonymous listener in this process, and a real client talking to it.
final class InProcessHelper {
    let directory: TemporaryDirectory
    let store: ModStore
    let listener: NSXPCListener
    let server: HelperServer
    let removedJob = Locked(0)
    let exited = Locked(0)
    let installedHelper: URL
    let bundledHelper: URL
    let plist: URL

    init(clientRequirement: String?, clientUID: uid_t = getuid(), idleInterval: TimeInterval = 3600, memoryTools: MemoryTools = .production) throws {
        directory = try TemporaryDirectory()
        store = try makeStore(in: directory)
        installedHelper = try directory.write("helper binary", to: "installed/helper")
        bundledHelper = try directory.write("helper binary", to: "bundle/ToolsyHelper")
        plist = try directory.write("plist", to: "LaunchDaemons/test.plist")
        listener = NSXPCListener.anonymous()
        let removedJob = removedJob
        let exited = exited
        server = HelperServer(
            service: HelperService(store: store, installedFiles: [plist, installedHelper], memoryTools: memoryTools),
            clientUID: clientUID,
            idleInterval: idleInterval,
            removeLaunchdJob: { removedJob.withLock { $0 += 1 } },
            exitProcess: { exited.withLock { $0 += 1 } }
        )
        if let clientRequirement {
            server.serve(on: listener, clientRequirement: clientRequirement)
        }
    }

    func client(timeouts: HelperClient.Timeouts = HelperClient.Timeouts(), runAsAdministrator: (@Sendable (String) async throws -> Void)? = nil) -> HelperClient {
        let endpoint = listener.endpoint
        return HelperClient(configuration: HelperClient.Configuration(
            installedHelper: installedHelper,
            launchdPlist: plist,
            bundledHelper: bundledHelper,
            connect: { NSXPCConnection(listenerEndpoint: endpoint) },
            installLayout: InstallLayout.production,
            runAsAdministrator: runAsAdministrator ?? { _ in Issue.record("unexpected administrator prompt") },
            timeouts: timeouts
        ))
    }
}

extension HelperClient.Timeouts {
    static let short = HelperClient.Timeouts(
        hello: .milliseconds(500), operation: .milliseconds(500), approve: .milliseconds(500),
        run: .milliseconds(500), startAfterInstall: .seconds(2)
    )
}

/// The test process's own requirement, computed exactly as `install()` does.
func ownRequirement() throws -> String {
    requirement(cdhash: try CodeIdentity.currentCDHash())
}

/// A `Mutex` that closures can capture: Mutex itself is non-copyable.
final class Locked<Value: Sendable>: Sendable {
    private let mutex: Mutex<Value>

    init(_ value: Value) {
        mutex = Mutex(value)
    }

    func withLock<Result: Sendable>(_ body: (inout Value) -> Result) -> Result {
        mutex.withLock { body(&$0) }
    }
}
