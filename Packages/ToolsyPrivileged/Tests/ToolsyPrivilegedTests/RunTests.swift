import Foundation
import Testing
@testable import ToolsyHelperCore
import ToolsyShared

@Suite struct RunTests {
    private let directory: TemporaryDirectory
    private let service: HelperService

    init() async throws {
        directory = try TemporaryDirectory()
        service = HelperService(store: try makeStore(in: directory), installedFiles: [])
        try await service.approve(modID: ProbeMod.id, files: ProbeMod.files(), executables: ProbeMod.executables)
    }

    private func run(_ command: String, input: CommandInput? = nil, modID: String = ProbeMod.id) async throws -> CommandResult {
        try await service.run(modID: modID, command: command, input: ProbeMod.encoded(input ?? ProbeMod.input(command)))
    }

    private func failure(_ command: String, input: Data? = nil, modID: String = ProbeMod.id) async -> String {
        do {
            _ = try await service.run(modID: modID, command: command, input: input ?? ProbeMod.encoded(ProbeMod.input(command)))
            return "ran"
        } catch {
            return error.localizedDescription
        }
    }

    @Test func runsFromTheSnapshotWithThePrivilegedEnvironment() async throws {
        let result = try await run("env", input: ProbeMod.input("env", key: "level", value: 9))
        #expect(result.succeeded)
        let output = keyValues(result.stdout)
        let snapshot = service.store.snapshotDirectory(ProbeMod.id)
        let dataDirectory = service.store.dataDirectory(ProbeMod.id)
        #expect(output["self"] == snapshot.appending(path: "bin/probe.sh").path(percentEncoded: false))
        #expect(output["pwd"] == realPath(snapshot))
        #expect(output["arg"] == "one arg")
        #expect(output["HOME"] == "/var/root")
        #expect(output["USER"] == "root")
        #expect(output["PATH"] == "/usr/bin:/bin:/usr/sbin:/sbin")
        // A folder of the user the helper runs as (root, in production) that nobody else can write to, unlike /tmp.
        let temporary = URL(filePath: try #require(output["TMPDIR"]), directoryHint: .isDirectory)
        #expect(try owner(of: temporary) == getuid())
        #expect(try mode(of: temporary) & 0o022 == 0)
        #expect(output["TOOLSY_MOD_ID"] == ProbeMod.id)
        #expect(output["TOOLSY_MOD_DIR"] == snapshot.path(percentEncoded: false))
        #expect(output["TOOLSY_DATA_DIR"] == dataDirectory.path(percentEncoded: false))
        #expect(output["TOOLSY_EVENT"] == "command")
        #expect(output["TOOLSY_COMMAND"] == "env")
        #expect(output["TOOLSY_KEY"] == "level")
        #expect(output["TOOLSY_VALUE"] == "9")
        #expect(output["TOOLSY_STATE_level"] == "7")
        #expect(output["stdin"] == "")
        #expect(try mode(of: dataDirectory) == 0o700)
    }

    @Test func feedsTheValidatedInputOnlyWhenDeclared() async throws {
        let input = ProbeMod.input("echo", key: "host", value: "a\"b")
        let echoed = try await run("echo", input: input)
        #expect(try JSONDecoder().decode(CommandInput.self, from: echoed.stdout) == input)

        let withoutStdin = try await run("nostdin")
        #expect(text(withoutStdin.stdout) == "0\n")
    }

    @Test func runsTheApprovedVersionOnly() async throws {
        #expect(keyValues(try await run("env").stdout)["version"] == "1")
        try await service.approve(modID: ProbeMod.id, files: ProbeMod.files(version: "2"), executables: ProbeMod.executables)
        #expect(keyValues(try await run("env").stdout)["version"] == "2")
    }

    @Test func refusesWhatIsNotAnApprovedPrivilegedCommand() async throws {
        #expect(await failure("plain") == "probe/plain is not a privileged command")
        #expect(await failure("missing") == "probe has no command missing")
        #expect(await failure("env", modID: "unknown") == HelperError.notApproved.localizedDescription)
        #expect(await failure("env", modID: "../probe") == "invalid mod id")
        #expect(await failure("bad name") == "invalid command name")
        #expect(await failure(String(repeating: "a", count: 65)) == "invalid command name")
    }

    @Test func refusesHostileInput() async throws {
        #expect(await failure("env", input: Data("not json".utf8)) == "the command input is not valid")
        #expect(await failure("env", input: try ProbeMod.encoded(ProbeMod.input("echo"))) == "the command input names another command")
        var badKey = ProbeMod.input("env")
        badKey.state["X=Y"] = "z"
        #expect(await failure("env", input: try ProbeMod.encoded(badKey)) == "the command input contains an invalid state key")
        #expect(await failure("env", input: try ProbeMod.encoded(ProbeMod.input("env", key: "a b"))) == "the command input contains an invalid state key")
        #expect(await failure("env", input: try ProbeMod.encoded(ProbeMod.input("env", value: "a\u{0}b"))) == "the command input contains NUL characters")
        let huge = Data(count: HelperService.maxInputBytes + 1)
        #expect(await failure("env", input: huge).hasPrefix("the command input is larger than"))
    }

    @Test func honoursTheCommandTimeout() async throws {
        let started = ContinuousClock.now
        let result = try await run("slow")
        #expect(result.timedOut && !result.succeeded)
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test func revokedModsCannotRun() async throws {
        try await service.revoke(modID: ProbeMod.id, keepingData: false)
        #expect(await failure("env") == HelperError.notApproved.localizedDescription)
    }
}
