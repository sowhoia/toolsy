import Darwin

/// CPU load over the interval since the previous sample, 0...1.
struct CPULoad: Equatable {
    var total: Double
    var user: Double
    var system: Double
    /// One entry per logical CPU, in the kernel's order.
    var cores: [Double]
}

/// Computes CPU load from the per-processor tick counters of `host_processor_info`.
final class CPUSampler {
    private var previous: [UInt32]?

    /// Forgets the previous counters; the next `sample()` only sets a new baseline.
    func reset() {
        previous = nil
    }

    /// Load since the previous call, or nil for the first call (which records the baseline).
    func sample() -> CPULoad? {
        guard let ticks = Self.readTicks() else { return nil }
        defer { previous = ticks }
        guard let previous, previous.count == ticks.count else { return nil }

        let states = Int(CPU_STATE_MAX)
        var cores: [Double] = []
        var user: UInt64 = 0, system: UInt64 = 0, busy: UInt64 = 0, all: UInt64 = 0
        for cpu in 0..<(ticks.count / states) {
            // The counters are 32-bit and wrap; wrapping subtraction still gives the delta.
            func delta(_ state: Int32) -> UInt64 {
                let index = cpu * states + Int(state)
                return UInt64(ticks[index] &- previous[index])
            }
            let coreUser = delta(CPU_STATE_USER) + delta(CPU_STATE_NICE)
            let coreSystem = delta(CPU_STATE_SYSTEM)
            let coreTotal = coreUser + coreSystem + delta(CPU_STATE_IDLE)
            cores.append(coreTotal > 0 ? Double(coreUser + coreSystem) / Double(coreTotal) : 0)
            user += coreUser
            system += coreSystem
            busy += coreUser + coreSystem
            all += coreTotal
        }
        guard all > 0 else { return nil }
        return CPULoad(
            total: Double(busy) / Double(all),
            user: Double(user) / Double(all),
            system: Double(system) / Double(all),
            cores: cores
        )
    }

    private static func readTicks() -> [UInt32]? {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let result = host_processor_info(machHost, PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount)
        guard result == KERN_SUCCESS, let info else { return nil }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride))
        }
        return (0..<Int(infoCount)).map { UInt32(bitPattern: info[$0]) }
    }
}
