import Foundation
import Testing
@testable import ToolsyShared

private func shell(_ script: String, stdin: Data? = nil, timeout: TimeInterval = 10, outputLimit: Int = 1024 * 1024) -> ProcessRunner.Request {
    ProcessRunner.Request(
        executable: URL(filePath: "/bin/sh"), arguments: ["-c", script],
        environment: ["PATH": "/usr/bin:/bin"], stdin: stdin, timeout: timeout, outputLimit: outputLimit
    )
}

private func text(_ data: Data) -> String {
    String(decoding: data, as: UTF8.self)
}

private func isAlive(_ pid: Int32) -> Bool {
    kill(pid, 0) == 0
}

@Suite struct ProcessRunnerTests {
    @Test func capturesOutputAndExitCode() async throws {
        let result = try await ProcessRunner.run(shell("echo out; echo err >&2; exit 3"))
        #expect(result.exitCode == 3)
        #expect(text(result.stdout) == "out\n")
        #expect(text(result.stderr) == "err\n")
        #expect(!result.timedOut && !result.succeeded)
    }

    @Test func passesArgumentsEnvironmentAndDirectory() async throws {
        let directory = try TemporaryDirectory()
        try directory.write("from the working directory", to: "marker.txt")
        var request = shell(#"echo "$GREETING $0 $1"; cat marker.txt"#)
        request.arguments += ["zero", "one"]
        request.environment["GREETING"] = "hello"
        request.currentDirectory = directory.url
        let result = try await ProcessRunner.run(request)
        #expect(text(result.stdout) == "hello zero one\nfrom the working directory")
        #expect(result.succeeded)
    }

    @Test func doesNotInheritTheCallersEnvironment() async throws {
        let result = try await ProcessRunner.run(shell(#"echo "home=[$HOME]""#))
        #expect(text(result.stdout) == "home=[]\n")
    }

    @Test func feedsStandardInput() async throws {
        let payload = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0) })
        var request = ProcessRunner.Request(executable: URL(filePath: "/bin/cat"), stdin: payload)
        request.timeout = 10
        let result = try await ProcessRunner.run(request)
        #expect(result.stdout == payload)
    }

    @Test func survivesAProgramThatIgnoresItsInput() async throws {
        // Far more than a pipe buffer holds: the write would raise SIGPIPE if it were not suppressed.
        let result = try await ProcessRunner.run(shell("exit 0", stdin: Data(count: 4 * 1024 * 1024)))
        #expect(result.succeeded)
    }

    @Test func standardInputIsEmptyByDefault() async throws {
        let result = try await ProcessRunner.run(shell("wc -c | tr -d ' '"))
        #expect(text(result.stdout) == "0\n")
    }

    @Test func killsTheWholeProcessGroupOnTimeout() async throws {
        let started = Date()
        let result = try await ProcessRunner.run(shell("sleep 30 & echo $!; wait", timeout: 0.3))
        #expect(result.timedOut && !result.succeeded)
        #expect(result.exitCode == 128 + SIGTERM)
        #expect(Date().timeIntervalSince(started) < 5)
        let grandchild = try #require(Int32(text(result.stdout).trimmingCharacters(in: .whitespacesAndNewlines)))
        try await Task.sleep(for: .milliseconds(200))
        #expect(!isAlive(grandchild))
    }

    @Test func escalatesToKillWhenTermIsIgnored() async throws {
        let started = Date()
        let result = try await ProcessRunner.run(shell("trap '' TERM; sleep 30", timeout: 0.2))
        #expect(result.timedOut)
        #expect(Date().timeIntervalSince(started) < 6)
    }

    @Test func doesNotWaitForDetachedDescendants() async throws {
        let started = Date()
        let result = try await ProcessRunner.run(shell("sleep 4 & echo done"))
        #expect(text(result.stdout) == "done\n")
        #expect(result.succeeded)
        #expect(Date().timeIntervalSince(started) < 3)
    }

    @Test func boundsCapturedOutput() async throws {
        let result = try await ProcessRunner.run(shell("head -c 300000 /dev/zero; echo tail >&2", outputLimit: 1000))
        #expect(result.stdout.count == 1000)
        #expect(text(result.stderr) == "tail\n")
        #expect(result.succeeded)
    }

    @Test func reportsSignals() async throws {
        let result = try await ProcessRunner.run(shell("kill -KILL $$"))
        #expect(result.exitCode == 128 + SIGKILL)
        #expect(!result.timedOut)
    }

    @Test func throwsWhenTheProgramCannotStart() async {
        await #expect(throws: ProcessRunnerError.self) {
            try await ProcessRunner.run(ProcessRunner.Request(executable: URL(filePath: "/nonexistent/tool")))
        }
    }

    @Test func cancellationKillsTheProgram() async throws {
        let directory = try TemporaryDirectory()
        let pidFile = directory.url.appending(path: "pid")
        let task = Task {
            try await ProcessRunner.run(shell("echo $$ > '\(pidFile.path(percentEncoded: false))'; sleep 30"))
        }
        var pid: Int32?
        for _ in 0..<100 where pid == nil {
            try await Task.sleep(for: .milliseconds(50))
            pid = (try? String(contentsOf: pidFile, encoding: .utf8)).flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        let child = try #require(pid)
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!isAlive(child))
    }

    @Test func runsManyCommandsConcurrently() async throws {
        try await withThrowingTaskGroup(of: (Int, CommandResult).self) { group in
            for index in 0..<40 {
                group.addTask { (index, try await ProcessRunner.run(shell("echo \(index)"))) }
            }
            for try await (index, result) in group {
                #expect(text(result.stdout) == "\(index)\n")
            }
        }
    }
}
