import Foundation

public struct ProcessRunnerError: LocalizedError, Equatable, Sendable {
    public let message: String

    public var errorDescription: String? { message }
}

/// Runs a program to completion with bounded time and bounded output.
public enum ProcessRunner {
    public struct Request: Sendable {
        public var executable: URL
        public var arguments: [String]
        /// The complete environment; nothing is inherited from the calling process.
        public var environment: [String: String]
        public var currentDirectory: URL?
        /// Written to the program's stdin, which is then closed. Without it stdin is `/dev/null`.
        public var stdin: Data?
        /// Seconds after which the program and everything it started are killed.
        public var timeout: TimeInterval
        /// Bytes kept per output stream; anything beyond is read and dropped.
        public var outputLimit: Int

        public init(
            executable: URL,
            arguments: [String] = [],
            environment: [String: String] = [:],
            currentDirectory: URL? = nil,
            stdin: Data? = nil,
            timeout: TimeInterval = ModCommand.defaultTimeout,
            outputLimit: Int = 1024 * 1024
        ) {
            self.executable = executable
            self.arguments = arguments
            self.environment = environment
            self.currentDirectory = currentDirectory
            self.stdin = stdin
            self.timeout = timeout
            self.outputLimit = outputLimit
        }
    }

    /// Non-zero exits and timeouts are reported in the result. The call throws only when the program
    /// cannot be started or the surrounding task is cancelled (which also kills the program).
    public static func run(_ request: Request) async throws -> CommandResult {
        let execution = Execution(request: request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { execution.start(resuming: $0) }
        } onCancel: {
            execution.cancel()
        }
    }
}

private final class Execution: @unchecked Sendable {
    private let request: ProcessRunner.Request
    private let process = Process()
    private let outputPipes = [Pipe(), Pipe()]
    private let inputPipe: Pipe?
    private let streamsClosed = DispatchGroup()
    private let lock = NSLock()
    // Guarded by `lock`.
    private var output = [Data(), Data()]
    private var streamIsOpen = [true, true]
    private var launched = false
    private var finished = false
    private var timedOut = false
    private var cancelled = false

    init(request: ProcessRunner.Request) {
        self.request = request
        inputPipe = request.stdin == nil ? nil : Pipe()
    }

    func start(resuming continuation: CheckedContinuation<CommandResult, any Error>) {
        process.executableURL = request.executable
        process.arguments = request.arguments
        process.environment = request.environment
        process.currentDirectoryURL = request.currentDirectory
        process.standardInput = inputPipe ?? FileHandle.nullDevice
        process.standardOutput = outputPipes[0]
        process.standardError = outputPipes[1]

        for index in outputPipes.indices {
            streamsClosed.enter()
            outputPipes[index].fileHandleForReading.readabilityHandler = { [self] handle in
                read(from: handle, stream: index)
            }
        }
        process.terminationHandler = { [self] process in
            lock.withLock { finished = true }
            // The waits below must not hold up the queue on which Foundation reports every process's exit.
            DispatchQueue.global().async { [self] in
                Self.stopLeftovers(ofGroup: process.processIdentifier)
                // Something the program started outside its group may keep the pipes open; do not wait for that.
                _ = streamsClosed.wait(timeout: .now() + 0.5)
                closeStreams()
                process.terminationHandler = nil

                let (result, wasCancelled) = lock.withLock {
                    let signalled = process.terminationReason == .uncaughtSignal
                    let result = CommandResult(
                        exitCode: signalled ? 128 + process.terminationStatus : process.terminationStatus,
                        stdout: output[0],
                        stderr: output[1],
                        timedOut: timedOut
                    )
                    return (result, cancelled)
                }
                if wasCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    continuation.resume(returning: result)
                }
            }
        }

        do {
            try process.run()
        } catch {
            closeStreams()
            process.terminationHandler = nil
            continuation.resume(throwing: ProcessRunnerError(
                message: "Cannot start \(request.executable.path(percentEncoded: false)): \(error.localizedDescription)"
            ))
            return
        }

        let cancelledBeforeLaunch = lock.withLock {
            launched = true
            return cancelled
        }
        if cancelledBeforeLaunch {
            terminate()
        }
        if let data = request.stdin {
            writeInput(data)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + request.timeout) { [weak self] in
            self?.expire()
        }
    }

    func cancel() {
        lock.withLock { cancelled = true }
        terminate()
    }

    private func expire() {
        let expired = lock.withLock {
            guard !finished else { return false }
            timedOut = true
            return true
        }
        if expired {
            terminate()
        }
    }

    private func terminate() {
        signalProcessGroup(SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.signalProcessGroup(SIGKILL)
        }
    }

    /// A program's run ends when it exits, and whatever it left running in its process group goes with it:
    /// otherwise the timeout, which only watches the program, would never reach those processes, and a
    /// root helper's lock would be released while they still worked on the files it guards. TERM first,
    /// then KILL for what ignores it. Only a mod's service is meant to run on, and it is not run here.
    static func stopLeftovers(ofGroup group: pid_t) {
        func hasMembers() -> Bool { kill(-group, 0) == 0 || errno == EPERM }
        // 0 and 1 would address the caller's own group and every process there is.
        guard group > 1, hasMembers() else { return }
        kill(-group, SIGTERM)
        let deadline = ContinuousClock.now + .seconds(2)
        while hasMembers(), ContinuousClock.now < deadline {
            usleep(20_000)
        }
        if hasMembers() {
            kill(-group, SIGKILL)
        }
    }

    /// Foundation starts every child as the leader of its own process group, so signalling the
    /// group also reaches whatever the program spawned.
    private func signalProcessGroup(_ signal: Int32) {
        lock.withLock {
            guard launched, !finished else { return }
            kill(-process.processIdentifier, signal)
        }
    }

    private func read(from handle: FileHandle, stream index: Int) {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        let count = Darwin.read(handle.fileDescriptor, &buffer, buffer.count)
        if count > 0 {
            lock.withLock {
                let room = request.outputLimit - output[index].count
                if room > 0 {
                    output[index].append(contentsOf: buffer[..<min(count, room)])
                }
            }
        } else if count == 0 || (errno != EINTR && errno != EAGAIN) {
            closeStream(index)
        }
    }

    private func closeStreams() {
        for index in outputPipes.indices {
            closeStream(index)
        }
    }

    private func closeStream(_ index: Int) {
        let wasOpen = lock.withLock {
            let wasOpen = streamIsOpen[index]
            streamIsOpen[index] = false
            return wasOpen
        }
        guard wasOpen else { return }
        outputPipes[index].fileHandleForReading.readabilityHandler = nil
        streamsClosed.leave()
    }

    private func writeInput(_ data: Data) {
        DispatchQueue.global().async { [self] in
            guard let handle = inputPipe?.fileHandleForWriting else { return }
            let descriptor = handle.fileDescriptor
            // A program that exits without reading its input must not take us down with SIGPIPE.
            _ = fcntl(descriptor, F_SETNOSIGPIPE, 1)
            data.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return }
                var offset = 0
                while offset < bytes.count {
                    let written = write(descriptor, base + offset, bytes.count - offset)
                    if written > 0 {
                        offset += written
                    } else if errno != EINTR {
                        break
                    }
                }
            }
            try? handle.close()
        }
    }
}
