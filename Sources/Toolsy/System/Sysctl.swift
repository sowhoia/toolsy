import Darwin

/// Typed reads of `sysctlbyname`. Values that do not exist or have an unexpected size are nil.
enum Sysctl {
    /// Reads a fixed-size value (an integer or a plain C struct such as `timeval`).
    static func value<T>(_ name: String, as type: T.Type = T.self) -> T? {
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { pointer.deallocate() }
        var size = MemoryLayout<T>.size
        guard sysctlbyname(name, pointer, &size, nil, 0) == 0, size == MemoryLayout<T>.size else { return nil }
        return pointer.pointee
    }

    static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(utf8String: buffer)
    }
}

/// The host port, obtained once: every `mach_host_self()` call adds a send right.
let machHost = mach_host_self()
