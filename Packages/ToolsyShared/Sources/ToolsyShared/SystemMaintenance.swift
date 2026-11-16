import Foundation

/// What one memory reclaim did. Each step runs even when the other one failed, so the app can say
/// truthfully that the work was done only in part.
public struct MemoryReclaimReport: Sendable, Equatable {
    /// `purge` flushed the disk cache.
    public var diskCacheFlushed: Bool
    /// Every process received the system's memory-pressure warning, and the system is back at the
    /// normal level.
    public var pressureWarningSent: Bool

    public init(diskCacheFlushed: Bool, pressureWarningSent: Bool) {
        self.diskCacheFlushed = diskCacheFlushed
        self.pressureWarningSent = pressureWarningSent
    }

    public var isComplete: Bool { diskCacheFlushed && pressureWarningSent }
    public var didAnything: Bool { diskCacheFlushed || pressureWarningSent }
}

/// System-wide maintenance that needs root but no approved mod. The real implementation is the
/// privileged helper; the operations take no parameters, so a client can only ask for them, never
/// change what they run.
public protocol SystemMaintaining: Sendable {
    /// Reclaims memory without terminating anything: flushes the disk cache, then holds the system at
    /// the *warn* memory-pressure level for a few seconds, on which processes return free pages and
    /// drop caches they can rebuild. Throws `PrivilegedError` like `PrivilegedExecuting`; `.busy`
    /// when a reclaim is already running.
    func reclaimMemory() async throws -> MemoryReclaimReport
}
