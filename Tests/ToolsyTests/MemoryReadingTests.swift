import Foundation
import Testing
import ToolsyShared
@testable import Toolsy

struct MemoryReadingTests {
    /// Used, cached files and free memory are separate parts of RAM; what is left is the kernel's own.
    @Test func thePartsOfMemoryAddUp() throws {
        let memory = try #require(MemoryReading.read())
        let parts = memory.used + memory.cachedFiles + memory.free
        #expect(memory.cachedFiles > 0 && memory.free > 0)
        #expect(parts <= memory.total)
        #expect(Double(parts) > Double(memory.total) * 0.85)
    }

    /// Cached files are what `vm_stat` calls file-backed plus purgeable pages (the speculative ones among the
    /// file-backed), and free memory is its free pages. Both are read moments apart, so they agree only roughly.
    @Test func agreesWithVMStat() async throws {
        let memory = try #require(MemoryReading.read())
        let result = try await ProcessRunner.run(ProcessRunner.Request(executable: URL(filePath: "/usr/bin/vm_stat"), timeout: 10))
        let output = String(decoding: result.stdout, as: UTF8.self)
        let pageSize = try #require(output.firstMatch(of: /page size of ([0-9]+) bytes/).flatMap { UInt64($0.1) })
        func pages(_ label: String) throws -> UInt64 {
            let line = try #require(output.split(separator: "\n").first { $0.hasPrefix(label + ":") })
            return try #require(UInt64(line.dropFirst(label.count + 1).trimmingCharacters(in: .whitespaces).dropLast()))
        }
        let cached = (try pages("File-backed pages") + pages("Pages purgeable")) * pageSize
        let free = try pages("Pages free") * pageSize
        func near(_ value: UInt64, _ expected: UInt64) -> Bool {
            abs(Double(value) - Double(expected)) < max(Double(expected) * 0.05, 256 * 1024 * 1024)
        }
        #expect(near(memory.cachedFiles, cached), "\(memory.cachedFiles) vs \(cached)")
        #expect(near(memory.free, free), "\(memory.free) vs \(free)")
    }
}
