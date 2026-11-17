import CryptoKit
import Foundation

public struct ModPayloadError: LocalizedError, Equatable, Sendable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}

/// The complete contents of a mod directory.
///
/// For a privileged mod this is what the user approves and what the helper snapshots into its
/// root-owned store, so the app and the helper must compute the same digest for the same files.
public struct ModPayload: Sendable, Equatable {
    public static let maxFileCount = 2_000
    public static let maxTotalBytes = 64 * 1024 * 1024

    /// Relative path → file contents.
    public let files: [String: Data]
    /// Relative paths that carry the executable bit.
    public let executables: Set<String>

    public init(files: [String: Data], executables: Set<String>) throws {
        guard files[ModManifest.fileName] != nil else {
            throw ModPayloadError("\(ModManifest.fileName) is missing")
        }
        guard files.count <= Self.maxFileCount else {
            throw ModPayloadError("a mod may contain at most \(Self.maxFileCount) files")
        }
        guard files.values.reduce(0, { $0 + $1.count }) <= Self.maxTotalBytes else {
            throw ModPayloadError("a mod may be at most \(Self.maxTotalBytes / 1024 / 1024) MB")
        }
        guard executables.isSubset(of: files.keys) else {
            throw ModPayloadError("an executable flag refers to a file that is not part of the mod")
        }
        // The default macOS file system is case-insensitive: two such paths would silently become one file.
        var seen: Set<String> = []
        for path in files.keys {
            guard Self.isSafeRelativePath(path) else {
                throw ModPayloadError("unsafe path in mod: \(path)")
            }
            guard seen.insert(path.lowercased()).inserted else {
                throw ModPayloadError("paths differ only by case: \(path)")
            }
        }
        for path in files.keys {
            var parent = path
            while let slash = parent.lastIndex(of: "/") {
                parent = String(parent[..<slash])
                guard !seen.contains(parent.lowercased()) else {
                    throw ModPayloadError("\(parent) is both a file and a directory")
                }
            }
        }
        self.files = files
        self.executables = executables
    }

    /// Reads a mod directory. Symbolic links and special files are refused rather than followed. Entries for
    /// which `skipped` holds (relative paths, folders with everything in them) are left out.
    public init(directory: URL, skipping skipped: (String) -> Bool = { _ in false }) throws {
        let root = directory.path(percentEncoded: false)
        guard let enumerator = FileManager.default.enumerator(atPath: root) else {
            throw ModPayloadError("cannot read \(root)")
        }
        var files: [String: Data] = [:]
        var executables: Set<String> = []
        var totalBytes = 0
        while let relative = enumerator.nextObject() as? String {
            let path = root + "/" + relative
            var info = stat()
            guard lstat(path, &info) == 0 else {
                throw ModPayloadError("cannot read \(relative): \(String(cString: strerror(errno)))")
            }
            if skipped(relative) {
                if info.st_mode & S_IFMT == S_IFDIR { enumerator.skipDescendants() }
                continue
            }
            switch info.st_mode & S_IFMT {
            case S_IFDIR: continue
            case S_IFREG: break
            default: throw ModPayloadError("\(relative): mods may contain only regular files and folders")
            }
            guard relative.split(separator: "/").last != ".DS_Store" else { continue }
            totalBytes += Int(info.st_size)
            guard files.count < Self.maxFileCount, totalBytes <= Self.maxTotalBytes else {
                throw ModPayloadError("the mod is too large")
            }
            files[relative] = try Data(contentsOf: URL(filePath: path))
            if info.st_mode & 0o111 != 0 {
                executables.insert(relative)
            }
        }
        try self.init(files: files, executables: executables)
    }

    public var manifestData: Data {
        files[ModManifest.fileName] ?? Data()
    }

    /// SHA-256 over every path, its executable flag and its contents, as lowercase hex.
    public var digest: String {
        var hasher = SHA256()
        for (path, data) in files.sorted(by: { $0.key < $1.key }) {
            // Paths cannot contain NUL, so the separator keeps the encoding unambiguous.
            hasher.update(data: Data(path.utf8))
            hasher.update(data: Data([0, executables.contains(path) ? 1 : 0]))
            hasher.update(data: Data(SHA256.hash(data: data)))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// A relative path that stays inside the mod: no absolute paths, no `.`/`..`, no control characters.
    public static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, path.utf8.count <= 512, !path.hasPrefix("/") else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { component in
            !component.isEmpty && component != "." && component != ".." && component.utf8.count <= 255
                && !component.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F || $0 == "\\" }
        }
    }
}
