import CoreServices
import Foundation

/// Reports changes below a directory through FSEvents, on the main queue. Watching ends when the
/// watcher is released.
final class FolderWatcher {
    /// The watched directory with symbolic links resolved, as FSEvents reports paths.
    private let root: String
    private let onChange: @MainActor ([String]) -> Void
    private var stream: FSEventStreamRef?

    /// `onChange` receives the changed paths relative to `directory`; "" stands for the directory itself,
    /// and for everything below it when FSEvents could not tell what changed.
    init(_ directory: URL, latency: TimeInterval, onChange: @escaping @MainActor ([String]) -> Void) throws {
        guard let resolved = realpath(directory.path(percentEncoded: false), nil) else {
            throw EngineError("Cannot watch \(directory.path(percentEncoded: false)): \(String(cString: strerror(errno)))")
        }
        root = String(cString: resolved)
        free(resolved)
        self.onChange = onChange
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
        guard let stream = FSEventStreamCreate(nil, { _, info, _, paths, _, _ in
            guard let info else { return }
            // The stream is invalidated in deinit, before the watcher it points to goes away.
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            // kFSEventStreamCreateFlagUseCFTypes: the paths are a CFArray of CFString.
            watcher.deliver(Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? [""])
        }, &context, [root] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags) else {
            throw EngineError("Cannot watch \(root): FSEvents refused the stream.")
        }
        FSEventStreamSetDispatchQueue(stream, .main)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            throw EngineError("Cannot watch \(root): FSEvents did not start.")
        }
        self.stream = stream
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    private func deliver(_ paths: [String]) {
        let prefix = root + "/"
        let relative = paths.map { $0.hasPrefix(prefix) ? String($0.dropFirst(prefix.count)) : "" }
        let onChange = onChange
        // The stream delivers on the main queue.
        MainActor.assumeIsolated { onChange(relative) }
    }
}
