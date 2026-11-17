import Darwin
import Foundation
import os
import ToolsyShared

/// A process by pid and start time: pids are reused, the pair is not.
nonisolated struct ProcessKey: Hashable, Sendable {
    var pid: pid_t
    /// `ri_proc_start_abstime` for the user's processes. Only root may read that of another user's process, so
    /// theirs is `p_starttime` in microseconds since 1970.
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
    /// A process of another user: root, a system daemon, another account.
    var isOfAnotherUser = false
}

/// One process in one sample.
nonisolated struct ProcessReading: Sendable {
    var key: ProcessKey
    var identity: ProcessIdentity
    /// `ri_phys_footprint`, what Activity Monitor's Memory column shows; nil for another user's process, which
    /// only root can measure.
    var footprint: UInt64?
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
        /// A process of another user, on its own whatever bundle it runs from.
        case otherUser(ProcessKey, executable: String)
    }

    var kind: Kind
    /// The footprints of its processes; nil when none of them could be measured.
    var memory: UInt64?
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
        if process.identity.isOfAnotherUser {
            return .otherUser(process.key, executable: process.identity.executable)
        }
        return process.identity.bundle.map { .bundle($0) } ?? .process(process.key, executable: process.identity.executable)
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
            var group = groups[kind] ?? ProcessGroupReading(kind: kind, memory: nil, cpu: 0, pids: [])
            if let footprint = process.footprint {
                group.memory = (group.memory ?? 0) + footprint
            }
            group.cpu += cpu
            group.pids.append(process.key.pid)
            groups[kind] = group
        }
        return Array(groups.values)
    }

    /// The CPU time of each of `processes` when the previous sample was taken at `previousTime`, given what that
    /// sample listed (`previous`). A process it did not list started since, so all its CPU time is recent; but
    /// one that started before it and was not listed then (it changed user, or listing raced its start) must not
    /// count its whole life, and counts from now on. `previousTime` is in the unit of the processes' start.
    static func baseline(of processes: [ProcessReading], previous: [ProcessKey: UInt64], previousTime: UInt64) -> [ProcessKey: UInt64] {
        previous.merging(
            processes.filter { $0.key.start < previousTime && previous[$0.key] == nil }.map { ($0.key, $0.cpuTime) },
            uniquingKeysWith: { first, _ in first }
        )
    }
}

/// What `ps -A -o pid=,time=` prints. `ps` is setuid root: unlike libproc it reads the CPU time of every
/// user's processes.
nonisolated enum PSOutput {
    struct Line: Equatable, Sendable {
        var pid: pid_t
        /// User plus system time, in hundredths of a second.
        var centiseconds: UInt64
    }

    /// Lines that do not read as one are skipped.
    static func lines(_ text: String) -> [Line] {
        text.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: " ")
            guard fields.count == 2, let pid = pid_t(fields[0]), let time = centiseconds(fields[1]) else { return nil }
            return Line(pid: pid, centiseconds: time)
        }
    }

    /// `[[days-]hours:]minutes:seconds.hundredths`, minutes going past 59 without hours: "0:15.34", "125:03.07".
    static func centiseconds(_ field: Substring) -> UInt64? {
        var clock = field
        var days: UInt64 = 0
        if let dash = field.firstIndex(of: "-") {
            guard let count = UInt64(field[..<dash]) else { return nil }
            days = count
            clock = field[field.index(after: dash)...]
        }
        let units = clock.split(separator: ":", omittingEmptySubsequences: false)
        let seconds = units.last?.split(separator: ".", omittingEmptySubsequences: false) ?? []
        guard (2...3).contains(units.count), seconds.count == 2, seconds[1].count == 2,
              let hours = units.count == 3 ? UInt64(units[0]) : 0, let minutes = UInt64(units[units.count - 2]),
              let wholeSeconds = UInt64(seconds[0]), let hundredths = UInt64(seconds[1]) else { return nil }
        return (((days * 24 + hours) * 60 + minutes) * 60 + wholeSeconds) * 100 + hundredths
    }
}

/// Reads the processes of the Mac off the main thread, one sample at a time. libproc describes only the user's
/// own processes to a process that is not root: for another user's (root, a system daemon, another account) it
/// refuses CPU time and footprint alike. On request the CPU time of those is read from `ps`, at the cost of a
/// short-lived process per sample; their footprint stays unknown.
actor ProcessSampler {
    private var identities: [ProcessKey: ProcessIdentity] = [:]
    private var previousCPU: [ProcessKey: UInt64] = [:]
    private var previousTime: UInt64?
    /// When the previous sample listed other users' processes, and their CPU times then.
    private var previousOtherUsers: (time: UInt64, wallTime: UInt64, cpu: [ProcessKey: UInt64])?
    private var isFailureReported = false

    private static let logger = Logger(subsystem: ToolsyPaths.bundleIdentifier, category: "processes")

    /// The groups since the previous call. `startingOver` forgets the previous call and only records the
    /// baseline for CPU use, returning nil. With `includingOtherUsers` every process of another user is a group
    /// of its own, once two samples in a row have listed them: CPU use is the change between two listings.
    func sample(startingOver: Bool = false, includingOtherUsers: Bool = false) async -> [ProcessGroupReading]? {
        // The only suspension, before anything of the sampler is read: a sample that ends after its task was
        // cancelled changes nothing.
        let listing = includingOtherUsers ? await listOtherUsers() : nil
        if Task.isCancelled { return nil }
        if startingOver { previousTime = nil }
        let now = mach_absolute_time()
        let (processes, others) = readProcesses(otherUsers: listing?.processes ?? [])
        let previousOthers = previousOtherUsers
        defer {
            previousCPU = Self.cpuTimes(of: processes)
            previousOtherUsers = listing.map { ($0.time, $0.wallTime, Self.cpuTimes(of: others)) }
            previousTime = now
        }
        guard let previousTime else { return nil }
        var groups = ProcessGrouping.groups(
            processes, previous: ProcessGrouping.baseline(of: processes, previous: previousCPU, previousTime: previousTime),
            elapsed: now - previousTime
        )
        if let listing, let previousOthers {
            groups += ProcessGrouping.groups(
                others, previous: ProcessGrouping.baseline(of: others, previous: previousOthers.cpu, previousTime: previousOthers.wallTime),
                elapsed: listing.time - previousOthers.time
            )
        }
        return groups
    }

    private static func cpuTimes(of processes: [ProcessReading]) -> [ProcessKey: UInt64] {
        Dictionary(processes.map { ($0.key, $0.cpuTime) }, uniquingKeysWith: { first, _ in first })
    }

    /// The user's processes, and the processes of other users from `listing` with what is known of them.
    private func readProcesses(otherUsers listing: [ListedProcess]) -> (own: [ProcessReading], others: [ProcessReading]) {
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
        var others: [ProcessReading] = []
        for process in listing {
            let identity = identities[process.key]
                ?? ProcessIdentity(executable: Self.executable(of: process.key.pid) ?? process.name, isOfAnotherUser: true)
            fresh[process.key] = identity
            others.append(ProcessReading(key: process.key, identity: identity, footprint: nil, cpuTime: process.cpuTime))
        }
        // Only processes that still exist stay cached.
        identities = fresh
        return (readings, others)
    }

    // MARK: Other users

    private struct ListedProcess {
        var key: ProcessKey
        /// The kernel's name of the process, for when its path cannot be read.
        var name: String
        /// In mach absolute time units.
        var cpuTime: UInt64
    }

    /// `time` and `wallTime` (microseconds since 1970) were taken as `ps` started.
    private struct OtherUsersListing {
        var time: UInt64
        var wallTime: UInt64
        var processes: [ListedProcess]
    }

    private static let psRequest = ProcessRunner.Request(
        executable: URL(filePath: "/bin/ps"), arguments: ["-A", "-o", "pid=,time="],
        // The decimal point of the time column follows the locale.
        environment: ["LC_ALL": "C"], timeout: 2
    )

    /// Every process of another user with its CPU time, as `ps` reports it. Nil when that failed; a failure is
    /// logged once until listing works again.
    private func listOtherUsers() async -> OtherUsersListing? {
        let time = mach_absolute_time()
        var now = timeval()
        gettimeofday(&now, nil)
        let failure: String
        do {
            let result = try await ProcessRunner.run(Self.psRequest)
            if !result.succeeded {
                failure = result.timedOut ? "ps timed out"
                    : "ps exited with status \(result.exitCode): \(String(decoding: result.stderr, as: UTF8.self))"
            } else if let table = Self.kernelProcesses() {
                isFailureReported = false
                let output = String(decoding: result.stdout, as: UTF8.self)
                return OtherUsersListing(time: time, wallTime: Self.microseconds(now),
                                         processes: Self.otherUsersProcesses(in: output, table: table))
            } else {
                failure = "the kernel's table of processes cannot be read"
            }
        } catch is CancellationError {
            return nil
        } catch {
            failure = error.localizedDescription
        }
        if !isFailureReported {
            isFailureReported = true
            Self.logger.error("other users' processes cannot be listed: \(failure, privacy: .public)")
        }
        return nil
    }

    /// The processes of other users among those `ps` printed. `table` is read after `ps` ran, so it knows every
    /// process `ps` listed that still runs.
    private static func otherUsersProcesses(in output: String, table: [kinfo_proc]) -> [ListedProcess] {
        let user = getuid(), app = getpid()
        let kernel = Dictionary(table.map { ($0.kp_proc.p_pid, $0) }, uniquingKeysWith: { first, _ in first })
        return PSOutput.lines(output).compactMap { line in
            guard let info = kernel[line.pid], info.kp_eproc.e_ucred.cr_uid != user else { return nil }
            let name = withUnsafeBytes(of: info.kp_proc.p_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            // `ps` lists itself, as a process of root.
            guard info.kp_eproc.e_ppid != app || name != "ps" else { return nil }
            return ListedProcess(key: ProcessKey(pid: line.pid, start: microseconds(info.kp_proc.p_un.__p_starttime)),
                                 name: name, cpuTime: machTime(centiseconds: line.centiseconds))
        }
    }

    /// The kernel's table of every process, which unlike libproc tells anyone who started each one, when, and as
    /// which user. One call for all: asked one by one, the processes of other users cost ten times as much.
    private static func kernelProcesses() -> [kinfo_proc]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        // Asked for the size first, with room for processes started between the calls; again if that was not enough.
        for _ in 0..<3 {
            var size = 0
            guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0 else { return nil }
            var table = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.size + 16)
            size = table.count * MemoryLayout<kinfo_proc>.size
            let result = table.withUnsafeMutableBytes { sysctl(&mib, u_int(mib.count), $0.baseAddress, &size, nil, 0) }
            if result == 0 { return Array(table.prefix(size / MemoryLayout<kinfo_proc>.size)) }
            guard errno == ENOMEM else { return nil }
        }
        return nil
    }

    private static func microseconds(_ time: timeval) -> UInt64 {
        UInt64(max(time.tv_sec, 0)) * 1_000_000 + UInt64(max(time.tv_usec, 0))
    }

    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    /// Hundredths of a second in mach absolute time units, the unit of the user's processes' CPU time.
    private static func machTime(centiseconds: UInt64) -> UInt64 {
        centiseconds * 10_000_000 * UInt64(timebase.denom) / UInt64(timebase.numer)
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
