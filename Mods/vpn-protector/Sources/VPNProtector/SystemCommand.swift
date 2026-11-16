import Darwin
import Foundation

struct SystemCommand {
    let status: Int32
    let output: String

    static func run(_ executable: String, _ arguments: [String], input: String? = nil) throws -> SystemCommand {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output

        // A regular file lets pfctl consume its input and print rules in either order.
        let inputFile = try input.map(openInputFile)
        defer { try? inputFile?.close() }
        process.standardInput = inputFile ?? FileHandle.nullDevice
        try process.run()
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return SystemCommand(status: process.terminationStatus, output: String(decoding: bytes, as: UTF8.self))
    }

    private static func openInputFile(_ input: String) throws -> FileHandle {
        var name = Array("/private/tmp/vpn-protector.XXXXXXXX".utf8CString)
        let descriptor = mkstemp(&name)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        guard unlink(name) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try handle.write(contentsOf: Data(input.utf8))
        try handle.seek(toOffset: 0)
        return handle
    }

    static func require(_ executable: String, _ arguments: [String], input: String? = nil) throws -> String {
        let result = try run(executable, arguments, input: input)
        guard result.status == 0 else {
            throw GuardError("\(executable) \(arguments.joined(separator: " ")) завершилась с кодом \(result.status).\n\(result.output)")
        }
        return result.output
    }

    static func pf(_ arguments: [String], input: String? = nil) throws -> String {
        try require("/sbin/pfctl", arguments, input: input).commandLines.filter {
            $0 != "No ALTQ support in kernel" && $0 != "ALTQ related functions disabled"
        }.joined(separator: "\n")
    }
}

extension String {
    var commandLines: [String] {
        split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
    }
}
