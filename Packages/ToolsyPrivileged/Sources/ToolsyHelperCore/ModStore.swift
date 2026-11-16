import Darwin
import Foundation
import ToolsyHelperXPC
import ToolsyShared

/// Why the helper did not do what it was asked.
public enum HelperError: LocalizedError, Equatable, Sendable {
    case failed(String)
    /// The mod has no approved snapshot.
    case notApproved
    /// A command of the mod is running; its snapshot cannot be replaced or removed meanwhile.
    case busy
    /// Another memory reclaim is running.
    case reclaimingMemory

    public var errorDescription: String? {
        switch self {
        case .failed(let message): message
        case .notApproved: "the mod is not approved"
        case .busy: "a command of the mod is still running"
        case .reclaimingMemory: "memory is already being reclaimed"
        }
    }

    /// `code` defaults to `errno` as it is at the call, before building the message can change it.
    static func posix(_ action: String, _ url: URL, code: Int32 = errno) -> HelperError {
        .failed("cannot \(action) \(url.path(percentEncoded: false)): \(String(cString: strerror(code)))")
    }
}

/// The root-owned store: approved snapshots under `Mods/<id>/` and the data folders of privileged
/// commands under `Data/<id>/`. Everything the helper executes comes from here.
///
/// A snapshot's payload digest is kept in an extended attribute of its directory, so the digest and
/// the files are replaced together by a single atomic rename.
struct ModStore: Sendable {
    static let digestAttribute = "app.toolsy.digest"

    let root: URL
    let ownerUID: uid_t

    var mods: URL { root.appending(path: "Mods", directoryHint: .isDirectory) }
    var data: URL { root.appending(path: "Data", directoryHint: .isDirectory) }
    var clientRequirement: URL { root.appending(path: HelperConstants.clientRequirementFileName) }
    var clientUser: URL { root.appending(path: HelperConstants.clientUserFileName) }

    /// Opens the store, creating `Mods` and `Data` on first use. Refuses a store that someone other than
    /// `ownerUID` could have written to, since its contents decide what runs as root.
    ///
    /// Nobody else can read the two folders either: whoever could copy an approved snapshot could put a
    /// mod back in place, byte for byte, after its owner removed it.
    init(root: URL, ownerUID: uid_t) throws {
        self.root = root
        self.ownerUID = ownerUID
        try FileChecks.requireProtected(root, ownerUID: ownerUID, type: S_IFDIR)
        for directory in [mods, data] {
            try FileChecks.makeDirectory(directory, mode: 0o700, allowExisting: true)
            try FileChecks.requireProtected(directory, ownerUID: ownerUID, type: S_IFDIR)
        }
    }

    func snapshotDirectory(_ id: String) -> URL {
        mods.appending(path: id)
    }

    func dataDirectory(_ id: String) -> URL {
        data.appending(path: id)
    }

    /// Valid ids never start with a dot, so staging directories cannot collide with snapshots.
    private func stagingDirectory(_ id: String) -> URL {
        mods.appending(path: ".\(id).staging")
    }

    func hasSnapshot(_ id: String) -> Bool {
        FileChecks.type(of: snapshotDirectory(id)) == S_IFDIR
    }

    /// Mod id → payload digest of every approved snapshot.
    func approvedDigests() throws -> [String: String] {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: mods.path(percentEncoded: false))
        } catch {
            throw HelperError.failed("cannot list approved mods: \(error.localizedDescription)")
        }
        var digests: [String: String] = [:]
        for name in names where !name.hasPrefix(".") {
            guard ModManifest.isValidID(name) else {
                throw HelperError.failed("unexpected entry in the store: \(name)")
            }
            digests[name] = try readDigest(of: snapshotDirectory(name))
        }
        return digests
    }

    /// Writes `payload` as the snapshot of `id`, replacing an earlier one atomically.
    func store(_ payload: ModPayload, as id: String) throws {
        let staging = stagingDirectory(id)
        // Left behind if the helper died while approving or revoking this mod.
        try FileChecks.removeIfPresent(staging)
        try FileChecks.makeDirectory(staging, mode: 0o755, allowExisting: false)
        for path in payload.files.keys.sorted() {
            var directory = staging
            for component in path.split(separator: "/").dropLast() {
                directory.append(path: String(component), directoryHint: .isDirectory)
                // Accepting an existing directory also covers two spellings of one folder on a
                // case-insensitive volume; files themselves never collide (ModPayload checks that).
                try FileChecks.makeDirectory(directory, mode: 0o755, allowExisting: true)
            }
            let mode: mode_t = payload.executables.contains(path) ? 0o755 : 0o644
            try FileChecks.writeNewFile(staging.appending(path: path), contents: payload.files[path] ?? Data(), mode: mode)
        }
        try writeDigest(payload.digest, to: staging)
        // Files were fsynced one by one; one full flush makes all of them durable before they become visible.
        try FileChecks.flushToDisk(staging)

        let target = snapshotDirectory(id)
        let hadSnapshot = FileChecks.type(of: target) != nil
        let flags = hadSnapshot ? RENAME_SWAP : RENAME_EXCL
        guard renamex_np(staging.path(percentEncoded: false), target.path(percentEncoded: false), UInt32(flags)) == 0 else {
            throw HelperError.posix("move the new snapshot into place at", target)
        }
        try FileChecks.flushToDisk(mods)
        if hadSnapshot {
            // After the swap the staging directory holds the previous snapshot.
            try FileChecks.removeIfPresent(staging)
        }
    }

    /// Deletes the snapshot of `id` and, unless `keepingData`, its data folder. Missing ones are not an error.
    func remove(_ id: String, keepingData: Bool) throws {
        let snapshot = snapshotDirectory(id)
        if FileChecks.type(of: snapshot) != nil {
            let staging = stagingDirectory(id)
            try FileChecks.removeIfPresent(staging)
            // Renamed first so that a crash halfway through deleting never leaves a partial
            // snapshot that still counts as approved.
            guard rename(snapshot.path(percentEncoded: false), staging.path(percentEncoded: false)) == 0 else {
                throw HelperError.posix("revoke", snapshot)
            }
            try FileChecks.removeIfPresent(staging)
        }
        if !keepingData {
            try FileChecks.removeIfPresent(dataDirectory(id))
        }
    }

    /// The data folder of `id`, created owner-only on first use.
    func prepareDataDirectory(_ id: String) throws -> URL {
        let directory = dataDirectory(id)
        try FileChecks.makeDirectory(directory, mode: 0o700, allowExisting: true)
        return directory
    }

    private func writeDigest(_ digest: String, to directory: URL) throws {
        let bytes = Array(digest.utf8)
        guard setxattr(directory.path(percentEncoded: false), Self.digestAttribute, bytes, bytes.count, 0, XATTR_NOFOLLOW) == 0 else {
            throw HelperError.posix("record the digest of", directory)
        }
    }

    /// Nil when the snapshot was revoked since the directory was listed (listing takes no lock).
    private func readDigest(of directory: URL) throws -> String? {
        var buffer = [UInt8](repeating: 0, count: 128)
        let size = getxattr(directory.path(percentEncoded: false), Self.digestAttribute, &buffer, buffer.count, 0, XATTR_NOFOLLOW)
        guard size >= 0 else {
            if errno == ENOENT { return nil }
            throw HelperError.posix("read the digest of", directory)
        }
        let digest = String(decoding: buffer[..<size], as: UTF8.self)
        guard digest.wholeMatch(of: /[0-9a-f]{64}/) != nil else {
            throw HelperError.failed("the recorded digest of \(directory.path(percentEncoded: false)) is malformed")
        }
        return digest
    }
}

/// The code requirement every XPC peer must satisfy, written by the installer.
enum ClientRequirement {
    static func load(from url: URL, ownerUID: uid_t) throws -> String {
        // Exactly this form and nothing else: the text goes straight into the listener, which throws
        // an Objective-C exception on a malformed requirement.
        guard let text = try FileChecks.protectedText(of: url, ownerUID: ownerUID), text.wholeMatch(of: /cdhash H"[0-9a-f]{40}"/) != nil else {
            throw HelperError.failed("\(url.path(percentEncoded: false)) does not contain a requirement of the form cdhash H\"<40 hex digits>\"")
        }
        return text
    }
}

/// The one user the helper works for, written by the installer: whoever installed it.
enum ClientUser {
    static func load(from url: URL, ownerUID: uid_t) throws -> uid_t {
        guard let text = try FileChecks.protectedText(of: url, ownerUID: ownerUID), text.wholeMatch(of: /[0-9]{1,10}/) != nil,
              let userID = uid_t(text) else {
            throw HelperError.failed("\(url.path(percentEncoded: false)) does not contain a user id")
        }
        return userID
    }
}

/// POSIX file operations with explicit modes and no symbolic-link following.
enum FileChecks {
    /// The file type bits of `url` without following a final symbolic link, or nil if nothing is there.
    static func type(of url: URL) -> mode_t? {
        var info = stat()
        guard lstat(url.path(percentEncoded: false), &info) == 0 else { return nil }
        return info.st_mode & S_IFMT
    }

    /// `url` must be of `type`, owned by `ownerUID` and writable by nobody else.
    static func requireProtected(_ url: URL, ownerUID: uid_t, type: mode_t) throws {
        let path = url.path(percentEncoded: false)
        var info = stat()
        guard lstat(path, &info) == 0 else {
            throw HelperError.posix("inspect", url)
        }
        guard info.st_mode & S_IFMT == type else {
            throw HelperError.failed("\(path) is not a \(type == S_IFDIR ? "directory" : "regular file")")
        }
        guard info.st_uid == ownerUID else {
            throw HelperError.failed("\(path) is owned by uid \(info.st_uid), expected \(ownerUID)")
        }
        guard info.st_mode & (S_IWGRP | S_IWOTH) == 0 else {
            throw HelperError.failed("\(path) is writable by group or others")
        }
    }

    /// The contents of a file only `ownerUID` could have written, or nil when they are not UTF-8.
    static func protectedText(of url: URL, ownerUID: uid_t) throws -> String? {
        try requireProtected(url, ownerUID: ownerUID, type: S_IFREG)
        do {
            return String(data: try Data(contentsOf: url), encoding: .utf8)
        } catch {
            throw HelperError.failed("cannot read \(url.path(percentEncoded: false)): \(error.localizedDescription)")
        }
    }

    /// Creates a directory with exactly `mode`, whatever the umask. With `allowExisting`, an existing
    /// directory (not a link to one) is accepted as it is.
    static func makeDirectory(_ url: URL, mode: mode_t, allowExisting: Bool) throws {
        let path = url.path(percentEncoded: false)
        if mkdir(path, mode) != 0 {
            guard errno == EEXIST, allowExisting else {
                throw HelperError.posix("create", url)
            }
            guard type(of: url) == S_IFDIR else {
                throw HelperError.failed("\(path) exists and is not a directory")
            }
            return
        }
        guard chmod(path, mode) == 0 else {
            throw HelperError.posix("set the mode of", url)
        }
    }

    /// Creates a file that must not exist yet, with exactly `mode`, and syncs it.
    static func writeNewFile(_ url: URL, contents: Data, mode: mode_t) throws {
        let descriptor = open(url.path(percentEncoded: false), O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)
        guard descriptor >= 0 else {
            throw HelperError.posix("create", url)
        }
        defer { close(descriptor) }
        guard fchmod(descriptor, mode) == 0 else {
            throw HelperError.posix("set the mode of", url)
        }
        let written = contents.withUnsafeBytes { bytes -> Bool in
            guard let base = bytes.baseAddress else { return true }
            var offset = 0
            while offset < bytes.count {
                let count = write(descriptor, base + offset, bytes.count - offset)
                if count > 0 {
                    offset += count
                } else if errno != EINTR {
                    return false
                }
            }
            return true
        }
        guard written, fsync(descriptor) == 0 else {
            throw HelperError.posix("write", url)
        }
    }

    /// Pushes everything written so far through the drive's cache (`fsync` alone does not on macOS).
    static func flushToDisk(_ directory: URL) throws {
        let descriptor = open(directory.path(percentEncoded: false), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw HelperError.posix("open", directory)
        }
        defer { close(descriptor) }
        guard fcntl(descriptor, F_FULLFSYNC) == 0 else {
            throw HelperError.posix("flush", directory)
        }
    }

    /// Deletes a file or a whole tree. Symbolic links inside are removed, never followed.
    static func removeIfPresent(_ url: URL) throws {
        guard type(of: url) != nil else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw HelperError.failed("cannot delete \(url.path(percentEncoded: false)): \(error.localizedDescription)")
        }
    }
}
