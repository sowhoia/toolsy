import Darwin
import Foundation
import ToolsyShared

/// `Run/<id>.json`: which process is a mod's service.
///
/// If Toolsy dies without stopping its services (a crash, a kill), a service that never writes
/// would run on unnoticed and a second copy would start beside it at the next launch. The record
/// lets that launch find the survivor and stop it.
struct ServiceRecord: Codable, Equatable {
    var pid: Int32
    /// When that process started. A recycled pid has another start time and belongs to somebody else.
    var startSeconds: Int
    var startMicroseconds: Int32

    static func directory(in directories: ToolsyDirectories) -> URL {
        directories.root.appending(path: "Run", directoryHint: .isDirectory)
    }

    static func file(for id: String, in directories: ToolsyDirectories) -> URL {
        directory(in: directories).appending(path: "\(id).json")
    }

    /// Describes a running process; nil if there is no such process.
    init?(pid: Int32) {
        guard let process = Self.lookUp(pid) else { return nil }
        self.pid = pid
        startSeconds = process.kp_proc.p_starttime.tv_sec
        startMicroseconds = process.kp_proc.p_starttime.tv_usec
    }

    func save(for id: String, in directories: ToolsyDirectories) throws {
        try FileManager.default.createDirectory(at: Self.directory(in: directories), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: Self.file(for: id, in: directories), options: .atomic)
    }

    static func remove(for id: String, in directories: ToolsyDirectories) {
        ModPackage.remove(file(for: id, in: directories))
    }

    /// Whether the recorded process is still running, as the leader of its own process group
    /// (which is how every service is started, and what makes signalling the group safe).
    var isRunning: Bool {
        guard pid > 1, let process = Self.lookUp(pid) else { return false }
        return process.kp_proc.p_starttime.tv_sec == startSeconds
            && process.kp_proc.p_starttime.tv_usec == startMicroseconds
            && process.kp_eproc.e_pgid == pid
    }

    /// Stops every recorded service that outlived the Toolsy that started it, then forgets the records.
    static func stopSurvivors(in directories: ToolsyDirectories, grace: Duration) async {
        let folder = directory(in: directories)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? []
        for name in names {
            let file = folder.appending(path: name)
            // A record that cannot be read identifies no process; like one of a process that is gone, it is only dropped.
            if let data = try? Data(contentsOf: file), let record = try? JSONDecoder().decode(ServiceRecord.self, from: data),
               record.isRunning {
                logger.notice("stopping a service left running by an earlier launch: \(name, privacy: .public), pid \(record.pid)")
                await terminateProcessGroup(ledBy: record.pid, grace: grace)
            }
            ModPackage.remove(file)
        }
    }

    private static func lookUp(_ pid: Int32) -> kinfo_proc? {
        var name = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var process = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&name, UInt32(name.count), &process, &size, nil, 0) == 0, size > 0 else { return nil }
        return process
    }
}
