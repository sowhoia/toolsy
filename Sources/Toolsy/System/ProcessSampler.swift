import Darwin

/// A process by pid and start time: pids are reused, the pair is not.
nonisolated struct ProcessKey: Hashable, Sendable {
    var pid: pid_t
    /// `ri_proc_start_abstime`.
    var start: UInt64
}

/// What does not change during a process's life, looked up once per process.
nonisolated struct ProcessIdentity: Sendable, Equatable {
    /// The executable's path, or the process name when the path cannot be read.
    var executable: String
    /// The outermost `.app` bundle the executable lives in.
    var bundle: String?
    /// For an XPC service, the process macOS holds responsible for it (the app it serves).
    var responsible: ProcessKey?
}

/// One process in one sample.
nonisolated struct ProcessReading: Sendable {
    var key: ProcessKey
    var identity: ProcessIdentity
    /// `ri_phys_footprint`, what Activity Monitor's Memory column shows.
    var footprint: UInt64
    /// User plus system time, in mach absolute time units.
    var cpuTime: UInt64
}

/// One group of the latest sample, before the app adds what only the main thread knows (running
/// applications, names, icons).
nonisolated struct ProcessGroupReading: Sendable, Equatable {
    enum Kind: Hashable, Sendable {
        /// Everything inside one outermost `.app` bundle, plus the XPC services it is responsible for.
        case bundle(String)
        /// A process outside any bundle, on its own.
        case process(ProcessKey, executable: String)
    }

    var kind: Kind
    var memory: UInt64
    /// 100 = one core busy all the time since the previous sample.
    var cpu: Double
    var pids: [pid_t]
}

/// Groups processes into what a person thinks of as one app. Pure, so the rules can be tested on
/// made-up processes.
nonisolated enum ProcessGrouping {
    /// `/Applications/Foo.app/Contents/Frameworks/Foo Helper.app/Contents/MacOS/Foo Helper` → `/Applications/Foo.app`.
    static func outermostBundle(of path: String) -> String? {
        guard path.hasPrefix("/") else { return nil }
        var prefix = ""
        for component in path.split(separator: "/").dropLast() {
            prefix += "/" + component
            if component.hasSuffix(".app") { return prefix }
        }
        return nil
    }

    static func isXPCService(_ path: String) -> Bool {
        path.contains(".xpc/")
    }

    /// The group of every process. Plain child processes are never attributed to their parent: a
    /// compiler started from a terminal is not the terminal.
    static func kind(of process: ProcessReading, among processes: [ProcessKey: ProcessReading]) -> ProcessGroupReading.Kind {
        if let responsible = process.identity.responsible, responsible != process.key,
           let owner = processes[responsible] {
            // One step only: the responsible process's own group, never its responsible process's.
            return ownKind(of: owner)
        }
        return ownKind(of: process)
    }

    private static func ownKind(of process: ProcessReading) -> ProcessGroupReading.Kind {
        process.identity.bundle.map { .bundle($0) } ?? .process(process.key, executable: process.identity.executable)
    }

    /// `previous` holds each process's CPU time at `elapsed` mach time units ago; processes missing
    /// from it started since then, so all their CPU time falls into the interval.
    static func groups(_ processes: [ProcessReading], previous: [ProcessKey: UInt64], elapsed: UInt64) -> [ProcessGroupReading] {
        let byKey = Dictionary(processes.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        var groups: [ProcessGroupReading.Kind: ProcessGroupReading] = [:]
        for process in processes {
            let kind = kind(of: process, among: byKey)
            let before = previous[process.key] ?? 0
            let used = process.cpuTime > before ? process.cpuTime - before : 0
            // CPU time and the interval are both in mach time units, so the timebase cancels out.
            let cpu = elapsed > 0 ? Double(used) / Double(elapsed) * 100 : 0
            groups[kind, default: ProcessGroupReading(kind: kind, memory: 0, cpu: 0, pids: [])].memory += process.footprint
            groups[kind]?.cpu += cpu
            groups[kind]?.pids.append(process.key.pid)
        }
        return Array(groups.values)
    }
}

/// Reads the current user's processes with libproc. Processes of other users cannot be read without
/// root and are not listed. Runs off the main thread; one sample at a time.
actor ProcessSampler {
    private var identities: [ProcessKey: ProcessIdentity] = [:]
    private var previousCPU: [ProcessKey: UInt64] = [:]
    private var previousTime: UInt64?

    /// The groups since the previous call. `startingOver` forgets the previous call and only records the
    /// baseline for CPU use, returning nil.
    func sample(startingOver: Bool = false) -> [ProcessGroupReading]? {
        if startingOver { previousTime = nil }
        let now = mach_absolute_time()
        let processes = readProcesses()
        defer {
            previousCPU = Dictionary(processes.map { ($0.key, $0.cpuTime) }, uniquingKeysWith: { first, _ in first })
            previousTime = now
        }
        guard let previousTime else { return nil }
        // A process that existed at the previous sample but was not listed then (it changed user, or
        // listing raced its start) must not count its whole life as recent CPU use.
        let previous = previousCPU.merging(
            processes.filter { $0.key.start < previousTime && previousCPU[$0.key] == nil }.map { ($0.key, $0.cpuTime) },
            uniquingKeysWith: { first, _ in first }
        )
        return ProcessGrouping.groups(processes, previous: previous, elapsed: now - previousTime)
    }

    private func readProcesses() -> [ProcessReading] {
        var readings: [ProcessReading] = []
        var newKeys: Set<ProcessKey> = []
        for pid in Self.userPIDs() {
            guard let usage = Self.usage(of: pid) else { continue }  // exited meanwhile
            let key = ProcessKey(pid: pid, start: usage.ri_proc_start_abstime)
            let identity: ProcessIdentity
            if let known = identities[key] {
                identity = known
            } else {
                guard let executable = Self.executable(of: pid) else { continue }
                identity = ProcessIdentity(executable: executable, bundle: ProcessGrouping.outermostBundle(of: executable))
                newKeys.insert(key)
            }
            readings.append(ProcessReading(key: key, identity: identity, footprint: usage.ri_phys_footprint,
                                           cpuTime: usage.ri_user_time + usage.ri_system_time))
        }
        // Responsibility is resolved once the start times of this sample are known, so that a reused
        // pid cannot be mistaken for the process that was responsible.
        let startByPID = Dictionary(readings.map { ($0.key.pid, $0.key.start) }, uniquingKeysWith: { first, _ in first })
        var fresh: [ProcessKey: ProcessIdentity] = [:]
        for index in readings.indices {
            let key = readings[index].key
            if newKeys.contains(key), ProcessGrouping.isXPCService(readings[index].identity.executable),
               let responsiblePID = Self.responsiblePID(for: key.pid), let start = startByPID[responsiblePID] {
                readings[index].identity.responsible = ProcessKey(pid: responsiblePID, start: start)
            }
            fresh[key] = readings[index].identity
        }
        // Only processes that still exist stay cached.
        identities = fresh
        return readings
    }

    // MARK: libproc

    private static func userPIDs() -> [pid_t] {
        let uid = getuid()
        // Asked for the size first, with room for processes started between the two calls.
        let needed = proc_listpids(UInt32(PROC_UID_ONLY), uid, nil, 0)
        guard needed > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(needed) / MemoryLayout<pid_t>.size + 64)
        let bytes = pids.withUnsafeMutableBytes { proc_listpids(UInt32(PROC_UID_ONLY), uid, $0.baseAddress, Int32($0.count)) }
        guard bytes > 0 else { return [] }
        return pids.prefix(Int(bytes) / MemoryLayout<pid_t>.size).filter { $0 > 0 }
    }

    /// The key of a running process of this user; nil when there is none with this pid.
    static func key(of pid: pid_t) -> ProcessKey? {
        usage(of: pid).map { ProcessKey(pid: pid, start: $0.ri_proc_start_abstime) }
    }

    private static func usage(of pid: pid_t) -> rusage_info_v6? {
        var info = rusage_info_v6()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            // proc_pid_rusage takes the buffer as `rusage_info_t *` (a pointer to void *) for historical
            // reasons; the kernel writes the flavor's struct there.
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) }
        }
        return result == 0 ? info : nil
    }

    private static func executable(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(4 * MAXPATHLEN))  // PROC_PIDPATHINFO_MAXSIZE
        if proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 || proc_name(pid, &buffer, UInt32(buffer.count)) > 0 {
            let text = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if !text.isEmpty { return text }
        }
        return nil
    }

    private typealias ResponsibilityFunction = @convention(c) (pid_t) -> pid_t

    /// `responsibility_get_pid_responsible_for_pid` is exported by libsystem but declared in no public
    /// header, so it is looked up at run time; without it XPC services form groups of their own.
    private static let responsibility: ResponsibilityFunction? = {
        // RTLD_DEFAULT, which Swift does not import: search every loaded image.
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else {
            return nil
        }
        return unsafeBitCast(symbol, to: ResponsibilityFunction.self)
    }()

    private static func responsiblePID(for pid: pid_t) -> pid_t? {
        guard let responsible = responsibility?(pid), responsible > 0, responsible != pid else { return nil }
        return responsible
    }
}
