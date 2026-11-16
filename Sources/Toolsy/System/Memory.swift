import Darwin

enum MemoryPressure: Equatable {
    case normal, warning, critical
}

struct MemoryReading: Equatable {
    /// "Memory Used" as Activity Monitor computes it: app memory + wired + compressed.
    var used: UInt64
    var total: UInt64
    var app: UInt64
    var wired: UInt64
    var compressed: UInt64
    /// "Cached Files" as Activity Monitor shows them: file-backed pages plus purgeable memory. Not part
    /// of `used`; the system drops these pages when it needs room, and a memory optimisation flushes them.
    var cachedFiles: UInt64
    /// What the system can hand out at once, without reclaiming anything: free pages, including the
    /// speculative ones read ahead from files (the kernel counts those as free).
    var free: UInt64
    var swapUsed: UInt64
    var pressure: MemoryPressure

    static func read() -> MemoryReading? {
        guard let total = Sysctl.value("hw.memsize", as: UInt64.self),
              let pageSize = Sysctl.value("hw.pagesize", as: Int64.self) else { return nil }
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(machHost, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        let page = UInt64(pageSize)
        // App memory is anonymous memory that cannot simply be dropped (purgeable can).
        let anonymous = UInt64(stats.internal_page_count)
        let purgeable = UInt64(stats.purgeable_count)
        let app = (anonymous > purgeable ? anonymous - purgeable : 0) * page
        let wired = UInt64(stats.wire_count) * page
        let compressed = UInt64(stats.compressor_page_count) * page
        // `external_page_count` includes the speculative pages; `free_count` does too (vm_stat prints
        // "Pages free" as free_count minus speculative_count).
        let cachedFiles = (UInt64(stats.external_page_count) + purgeable) * page
        let free = UInt64(stats.free_count) * page

        let pressure: MemoryPressure
        switch Sysctl.value("kern.memorystatus_vm_pressure_level", as: Int32.self) {
        case 4: pressure = .critical
        case 2: pressure = .warning
        default: pressure = .normal
        }
        let swap = Sysctl.value("vm.swapusage", as: xsw_usage.self)
        return MemoryReading(
            used: app + wired + compressed, total: total, app: app, wired: wired, compressed: compressed,
            cachedFiles: cachedFiles, free: free, swapUsed: swap?.xsu_used ?? 0, pressure: pressure
        )
    }
}
