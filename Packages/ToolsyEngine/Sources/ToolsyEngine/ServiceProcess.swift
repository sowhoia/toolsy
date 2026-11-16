import Foundation
import Synchronization
import ToolsyShared

/// The one long-lived process of a mod. Unlike `ProcessRunner` it delivers standard output line by line
/// while the program runs, and it has no timeout.
final class ServiceProcess: Sendable {
    enum Event: Sendable {
        case line(Data)
        /// Exit status (128 + signal number when killed) and the last non-empty line of standard error.
        case exit(status: Int32, lastErrorLine: String?)
    }

    /// A patch longer than this is not a patch but a runaway program; the line is dropped.
    static let maxLineLength = 256 * 1024
    static let errorTailLength = 4 * 1024

    let events: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation
    private let process = Process()
    private let pipes = [Pipe(), Pipe()]
    private let output = Mutex(Output())
    private let streamsClosed = DispatchGroup()

    struct Output {
        var pendingLine = Data()
        var droppingLine = false
        var errorTail = Data()
        var streamIsOpen = [true, true]
    }

    init(executable: URL, arguments: [String], environment: [String: String], directory: URL, input: Data?) throws {
        // A flood of lines must not grow memory without bound; the exit event is the newest and always kept.
        (events, continuation) = AsyncStream.makeStream(of: Event.self, bufferingPolicy: .bufferingNewest(10_000))
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = directory
        process.standardOutput = pipes[0]
        process.standardError = pipes[1]
        let inputPipe = input == nil ? nil : Pipe()
        process.standardInput = inputPipe ?? FileHandle.nullDevice

        for index in pipes.indices {
            streamsClosed.enter()
            pipes[index].fileHandleForReading.readabilityHandler = { [self] handle in
                read(from: handle, stream: index)
            }
        }
        // The handlers keep this object alive while the program runs; both are cleared when it ends.
        process.terminationHandler = { [self] process in
            // Something the service started may keep the pipes open; do not wait for that.
            _ = streamsClosed.wait(timeout: .now() + 0.5)
            closeStreams()
            process.terminationHandler = nil
            let status = process.terminationReason == .uncaughtSignal ? 128 + process.terminationStatus : process.terminationStatus
            continuation.yield(.exit(status: status, lastErrorLine: output.withLock { lastNonEmptyLine($0.errorTail) }))
            continuation.finish()
        }
        do {
            try process.run()
        } catch {
            closeStreams()
            process.terminationHandler = nil
            continuation.finish()
            throw EngineError("Cannot start \(executable.path(percentEncoded: false)): \(error.localizedDescription)")
        }
        if let input, let inputPipe {
            Self.write(input, to: inputPipe.fileHandleForWriting)
        }
    }

    var processIdentifier: Int32 { process.processIdentifier }

    /// Stops the service and everything it started.
    func terminateGroup(grace: Duration) async {
        await terminateProcessGroup(ledBy: process.processIdentifier, grace: grace)
    }

    private func read(from handle: FileHandle, stream index: Int) {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        let count = Darwin.read(handle.fileDescriptor, &buffer, buffer.count)
        if count > 0 {
            let chunk = buffer[..<count]
            output.withLock { output in
                if index == 0 {
                    // Yielding under the lock keeps lines in order across handler invocations.
                    for line in output.lines(appending: chunk) {
                        continuation.yield(.line(line))
                    }
                } else {
                    output.errorTail.append(contentsOf: chunk)
                    if output.errorTail.count > Self.errorTailLength {
                        output.errorTail = Data(output.errorTail.suffix(Self.errorTailLength))
                    }
                }
            }
        } else if count == 0 || (errno != EINTR && errno != EAGAIN) {
            closeStream(index)
        }
    }

    private func closeStreams() {
        for index in pipes.indices {
            closeStream(index)
        }
    }

    private func closeStream(_ index: Int) {
        let wasOpen = output.withLock { output in
            let wasOpen = output.streamIsOpen[index]
            output.streamIsOpen[index] = false
            // A last line without a trailing newline still counts.
            if wasOpen, index == 0, !output.droppingLine, !output.pendingLine.isEmpty {
                continuation.yield(.line(output.pendingLine))
                output.pendingLine = Data()
            }
            return wasOpen
        }
        guard wasOpen else { return }
        pipes[index].fileHandleForReading.readabilityHandler = nil
        streamsClosed.leave()
    }

    private static func write(_ data: Data, to handle: FileHandle) {
        DispatchQueue.global().async {
            let descriptor = handle.fileDescriptor
            // A service that exits without reading its input must not take the app down with SIGPIPE.
            _ = fcntl(descriptor, F_SETNOSIGPIPE, 1)
            data.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return }
                var offset = 0
                while offset < bytes.count {
                    let written = Darwin.write(descriptor, base + offset, bytes.count - offset)
                    if written > 0 {
                        offset += written
                    } else if errno != EINTR {
                        break
                    }
                }
            }
            do {
                try handle.close()
            } catch {
                logger.error("could not close the input of a service: \(error.localizedDescription)")
            }
        }
    }
}

extension ServiceProcess.Output {
    /// Splits off complete lines. A line that grows past the limit is dropped up to its newline.
    mutating func lines(appending chunk: ArraySlice<UInt8>) -> [Data] {
        var lines: [Data] = []
        var rest = chunk
        while let newline = rest.firstIndex(of: UInt8(ascii: "\n")) {
            let segment = rest[..<newline]
            if !droppingLine, pendingLine.count + segment.count <= ServiceProcess.maxLineLength {
                pendingLine.append(contentsOf: segment)
                lines.append(pendingLine)
            }
            pendingLine = Data()
            droppingLine = false
            rest = rest[(newline + 1)...]
        }
        if !droppingLine {
            pendingLine.append(contentsOf: rest)
            if pendingLine.count > ServiceProcess.maxLineLength {
                pendingLine = Data()
                droppingLine = true
                logger.error("dropped a service output line longer than \(ServiceProcess.maxLineLength) bytes")
            }
        }
        return lines
    }
}
