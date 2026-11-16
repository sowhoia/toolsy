import Foundation

/// The programs the memory reclaim runs and how long each may take. Production uses the system's
/// own tools by absolute path; tests substitute harmless stand-ins. Nothing here comes from a client.
struct MemoryTools: Sendable {
    /// Flushes the disk cache (`man purge`); anonymous memory is untouched.
    var purge: URL
    /// `memory_pressure -S` sets the system's pressure level by hand (`man memory_pressure`).
    var memoryPressure: URL
    /// `purge` writes out dirty pages first, which takes a while on a busy disk.
    var purgeTimeout: TimeInterval = 120
    /// The level is held for `warnSeconds`, so this leaves room for a slow start.
    var pressureTimeout: TimeInterval = 15
    var restoreTimeout: TimeInterval = 10

    static let production = MemoryTools(
        purge: URL(filePath: "/usr/sbin/purge"),
        memoryPressure: URL(filePath: "/usr/bin/memory_pressure")
    )

    /// Long enough for every process to receive the notification and act on it. The *critical* level is
    /// never used: on it apps may discard work in use, such as a browser's background tabs.
    static let warnSeconds = 3
    static let warnArguments = ["-S", "-l", "warn", "-s", String(warnSeconds)]
    /// The tool's own way back: it writes the normal level, then (after zero seconds) writes it again.
    static let normalArguments = ["-S", "-l", "normal", "-s", "0"]
    /// Neither tool needs anything from its environment.
    static let environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
}
