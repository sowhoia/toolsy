import Foundation
import ToolsyShared

/// The three package forms of MOD_FORMAT.md ("Packaging"): a `.toolsymod` zip, a folder, a lone `.json` manifest.
/// Installation and `toolsy-mod` run exactly the same checks through `read`.
public enum ModPackage {
    /// Runs every check installation runs and returns the manifest.
    public static func validate(_ package: URL) async throws -> ModManifest {
        let scratch = try temporaryDirectory(appropriateFor: nil)
        defer { remove(scratch) }
        return try await read(package, scratch: scratch).manifest
    }

    /// Validates `folder`, then writes it to `archive` as a zip with `mod.json` at the root, without
    /// `.DS_Store` files, with executable bits preserved, and the same bytes for the same files. An existing
    /// `archive` is replaced; it must be a `.toolsymod` file, so a mistyped `-o` never replaces a folder or
    /// some other file of the author's.
    public static func pack(_ folder: URL, to archive: URL) async throws -> ModManifest {
        guard isDirectory(folder) else {
            throw EngineError("\(folder.lastPathComponent) is not a folder")
        }
        guard archive.pathExtension.lowercased() == ToolsyPaths.modFileExtension else {
            throw EngineError("\(archive.lastPathComponent) is not a .\(ToolsyPaths.modFileExtension) file name")
        }
        var info = stat()
        if lstat(archive.path(percentEncoded: false), &info) == 0, info.st_mode & S_IFMT != S_IFREG {
            throw EngineError("\(archive.lastPathComponent) exists and is not a file")
        }
        // Next to the archive, so the finished zip can be moved into place atomically.
        let scratch = try temporaryDirectory(appropriateFor: archive.deletingLastPathComponent())
        defer { remove(scratch) }
        let (manifest, payload) = try await read(folder, scratch: scratch)
        let contents = scratch.appending(path: "contents", directoryHint: .isDirectory)
        try write(payload, to: contents)
        let zip = scratch.appending(path: "mod.zip")
        try await writeArchive(payload, from: contents, to: zip, failure: "\(archive.lastPathComponent) could not be written")
        try place(zip, at: archive)
        return manifest
    }

    /// Writes `payload`, already materialised in `contents`, so that the same files always give the same
    /// archive and anyone can check a published one against its sources: entries in path order, no folder
    /// entries, no owners or extra timestamps (`-X`), and one fixed date. Zip keeps that date as local time,
    /// so zip is told it is in UTC.
    private static func writeArchive(_ payload: ModPayload, from contents: URL, to archive: URL, failure: String) async throws {
        let paths = payload.files.keys.sorted()
        let fixedDate = Date(timeIntervalSinceReferenceDate: 0)
        for path in paths {
            try FileManager.default.setAttributes([.modificationDate: fixedDate], ofItemAtPath: contents.appending(path: path).path(percentEncoded: false))
        }
        let result = try await ProcessRunner.run(ProcessRunner.Request(
            executable: URL(filePath: "/usr/bin/zip"),
            arguments: ["-X", "-D", "-q", "-@", archive.path(percentEncoded: false)],
            environment: ["TZ": "UTC0"],
            currentDirectory: contents,
            stdin: Data(paths.map { $0 + "\n" }.joined().utf8),
            timeout: 60
        ))
        guard result.succeeded else {
            throw EngineError("\(failure): \(lastNonEmptyLine(result.stderr) ?? "zip exited with status \(result.exitCode)")")
        }
    }

    /// What lies around in an author's working folder but is never part of the mod: version control
    /// metadata, and packed mods, such as the previous `toolsy-mod pack` written into that folder.
    static func isAuthoringLeftover(_ relativePath: String) -> Bool {
        let components = relativePath.split(separator: "/")
        guard let name = components.last else { return false }
        return (components.count == 1 && [".git", ".hg", ".svn"].contains(name))
            || name.lowercased().hasSuffix(".\(ToolsyPaths.modFileExtension)")
    }

    /// Reads a package and checks it completely: manifest, templates and expressions, file rules, programs.
    /// `scratch` is an empty directory the package may be unpacked into.
    static func read(_ package: URL, scratch: URL) async throws -> (manifest: ModManifest, payload: ModPayload) {
        let payload: ModPayload
        if isDirectory(package) {
            payload = try ModPayload(directory: package, skipping: isAuthoringLeftover)
        } else {
            switch package.pathExtension.lowercased() {
            case ToolsyPaths.modFileExtension:
                payload = try await unpack(package, into: scratch.appending(path: "unpacked", directoryHint: .isDirectory))
            case "json":
                payload = try ModPayload(files: [ModManifest.fileName: Data(contentsOf: package)], executables: [])
            default:
                throw EngineError("\(package.lastPathComponent) is not a mod: expected a .\(ToolsyPaths.modFileExtension) file, a folder or a .json manifest")
            }
        }
        let manifest = try ModManifest.load(from: payload.manifestData)
        try manifest.validateTemplatesAndExpressions()
        try manifest.validatePrograms(in: payload)
        return (manifest, payload)
    }

    /// Unpacks and checks `package` into a new staging directory next to `modsDirectory`; the checked copy
    /// is at `<staging>/mod/`, and `payload` holds the same bytes. Nothing is left behind when a check fails.
    static func stage(_ package: URL, nextTo modsDirectory: URL) async throws -> (manifest: ModManifest, payload: ModPayload, staging: URL) {
        let staging = try temporaryDirectory(appropriateFor: modsDirectory)
        do {
            let (manifest, payload) = try await read(package, scratch: staging)
            try write(payload, to: PreparedInstall.modDirectory(in: staging))
            return (manifest, payload, staging)
        } catch {
            remove(staging)
            throw error
        }
    }

    /// Materialises a payload in a new directory. Writing the checked bytes, rather than copying the source,
    /// guarantees that what is installed is exactly what was validated.
    static func write(_ payload: ModPayload, to directory: URL) throws {
        let files = FileManager.default
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        for (path, data) in payload.files {
            let file = directory.appending(path: path)
            let location = file.path(percentEncoded: false)
            try files.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file)
            try files.setAttributes([.posixPermissions: payload.executables.contains(path) ? 0o755 : 0o644], ofItemAtPath: location)
            // The user chose to install this code; with the flag macOS refuses to run downloaded programs.
            guard removexattr(location, "com.apple.quarantine", XATTR_NOFOLLOW) == 0 || errno == ENOATTR else {
                throw EngineError("cannot clear the quarantine flag of \(path): \(String(cString: strerror(errno)))")
            }
        }
    }

    /// A new empty directory on the volume of `target` (the temporary directory when nil), so that what is
    /// built in it can be renamed into place.
    static func temporaryDirectory(appropriateFor target: URL?) throws -> URL {
        let files = FileManager.default
        guard let target else {
            let directory = files.temporaryDirectory.appending(path: "toolsy-\(UUID().uuidString)", directoryHint: .isDirectory)
            try files.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory
        }
        try files.createDirectory(at: target, withIntermediateDirectories: true)
        return try files.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: target, create: true)
    }

    /// Removes a temporary directory, if it is still there. A failure only leaves clutter in a temporary
    /// location, so it is logged, not thrown.
    static func remove(_ temporary: URL) {
        do {
            try FileManager.default.removeItem(at: temporary)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return
        } catch {
            logger.error("could not remove temporary folder: \(error.localizedDescription)")
        }
    }

    /// Moves `item` to `destination`, atomically replacing what is there.
    static func place(_ item: URL, at destination: URL) throws {
        let files = FileManager.default
        if files.fileExists(atPath: destination.path(percentEncoded: false)) {
            _ = try files.replaceItemAt(destination, withItemAt: item, options: .usingNewMetadataOnly)
        } else {
            try files.moveItem(at: item, to: destination)
        }
    }

    private static func unpack(_ archive: URL, into directory: URL) async throws -> ModPayload {
        let name = archive.lastPathComponent
        try await checkDeclaredSize(of: archive)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await ditto(["-x", "-k", archive.path(percentEncoded: false), directory.path(percentEncoded: false)],
                                failure: "\(name) could not be unpacked")
            }
            // What an archive declares is its author's word, and `ditto` writes whatever the data really holds.
            // Unpacking is therefore watched and stopped as soon as it outgrows a mod, long before the disk fills.
            group.addTask {
                while true {
                    try await Task.sleep(for: .milliseconds(50))
                    guard holdsNoMoreThanAMod(directory) else {
                        throw EngineError("\(name) unpacks to more than a mod may hold")
                    }
                }
            }
            // Whichever ends first decides: `ditto` finishing, or the watch refusing. Leaving the group stops the other.
            defer { group.cancelAll() }
            try await group.next()
        }
        return try ModPayload(directory: modRoot(in: directory))
    }

    /// Whether what has been unpacked into `directory` so far stays within the limits of a mod.
    private static func holdsNoMoreThanAMod(_ directory: URL) -> Bool {
        // A directory that is not there yet holds nothing.
        guard let entries = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey]) else { return true }
        var fileCount = 0, byteCount = 0
        for case let entry as URL in entries {
            // An entry that vanished or cannot be read counts as empty here; `ModPayload` reads everything strictly afterwards.
            let values = try? entry.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
            // The limit is on files, as `ModPayload` counts them; folders hold nothing of their own.
            guard values?.isDirectory != true else { continue }
            fileCount += 1
            byteCount += values?.fileSize ?? 0
            guard fileCount <= ModPayload.maxFileCount, byteCount <= ModPayload.maxTotalBytes else { return false }
        }
        return true
    }

    /// Turns away an archive whose own directory declares more than a mod may hold, before anything is
    /// written. The declaration can be false, so `unpack` also watches what is really written.
    private static func checkDeclaredSize(of archive: URL) async throws {
        let name = archive.lastPathComponent
        guard FileManager.default.isReadableFile(atPath: archive.path(percentEncoded: false)) else {
            throw EngineError("\(name) cannot be read")
        }
        let result = try await ProcessRunner.run(ProcessRunner.Request(
            executable: URL(filePath: "/usr/bin/zipinfo"), arguments: ["-t", archive.path(percentEncoded: false)]
        ))
        // "3 files, 377708 bytes uncompressed, 105668 bytes compressed:  72.0%"
        guard let totals = String(decoding: result.stdout, as: UTF8.self).firstMatch(of: /(\d+) files?, (\d+) bytes uncompressed/),
              let byteCount = Int(totals.2) else {
            throw EngineError("\(name) is not a zip archive")
        }
        // zipinfo counts every entry. The limit is on files, as `ModPayload` counts them, so folder entries and
        // the resource forks Finder's Compress adds under `__MACOSX/` are not counted against it.
        let names = try await ProcessRunner.run(ProcessRunner.Request(
            executable: URL(filePath: "/usr/bin/zipinfo"), arguments: ["-1", archive.path(percentEncoded: false)]
        ))
        let fileCount = String(decoding: names.stdout, as: UTF8.self).split(separator: "\n")
            .filter { !$0.hasSuffix("/") && !$0.hasPrefix("__MACOSX/") }.count
        guard fileCount <= ModPayload.maxFileCount, byteCount <= ModPayload.maxTotalBytes else {
            throw EngineError("\(name) declares \(fileCount) files and \(byteCount) bytes, more than a mod may hold")
        }
    }

    /// `mod.json` at the root of the archive, or inside its single top-level folder.
    private static func modRoot(in directory: URL) throws -> URL {
        let entries = try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))
            .filter { $0 != ".DS_Store" && $0 != "__MACOSX" }
        if entries.contains(ModManifest.fileName) {
            return directory
        }
        // A link would make the payload read files from outside the archive.
        if entries.count == 1, case let folder = directory.appending(path: entries[0], directoryHint: .isDirectory),
           isDirectory(folder),
           FileManager.default.fileExists(atPath: folder.appending(path: ModManifest.fileName).path(percentEncoded: false)) {
            return folder
        }
        throw EngineError("the archive has no \(ModManifest.fileName) at its root or inside a single top-level folder")
    }

    private static func ditto(_ arguments: [String], failure: String) async throws {
        let result = try await ProcessRunner.run(ProcessRunner.Request(
            executable: URL(filePath: "/usr/bin/ditto"), arguments: arguments, timeout: 60
        ))
        guard result.succeeded else {
            throw EngineError("\(failure): \(lastNonEmptyLine(result.stderr) ?? "ditto exited with status \(result.exitCode)")")
        }
    }

    /// A real directory; symbolic links are not followed.
    static func isDirectory(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path(percentEncoded: false), &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
    }
}

/// A mod unpacked and checked, waiting for the user's confirmation.
/// Finish it with `ModStore.commitInstall` or throw it away with `ModStore.discardInstall`.
public struct PreparedInstall: Sendable {
    public let manifest: ModManifest
    /// A mod with the same id is installed; it will be replaced and keep its settings.
    public let replacesInstalledMod: Bool
    /// Version of the installed mod being replaced, when it is loaded.
    public let installedVersion: String?
    /// Temporary directory on the volume of the mods folder; holds the checked copy under `mod/`.
    let staging: URL
    /// For a mod with privileged commands: the checked bytes themselves, which is what the helper is asked
    /// to approve. `manifest` was read from them, so the user confirms exactly what will run as root,
    /// whatever happens to the files on disk in between.
    let approval: ModPayload?

    /// Commands that will run as root, sorted; the confirmation lists them.
    public var privilegedCommands: [String] {
        manifest.commands.filter(\.value.privileged).keys.sorted()
    }

    var modDirectory: URL {
        Self.modDirectory(in: staging)
    }

    static func modDirectory(in staging: URL) -> URL {
        staging.appending(path: "mod", directoryHint: .isDirectory)
    }
}
