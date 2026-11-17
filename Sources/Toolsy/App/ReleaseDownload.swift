import Foundation
import Synchronization
import ToolsyShared

/// Downloads a file of a release the way the check asks for the release: a session without cookies, cache or
/// credentials, and nothing about the user in the request.
nonisolated final class ReleaseDownload: NSObject, URLSessionDownloadDelegate, Sendable {
    private struct State {
        var continuation: CheckedContinuation<Void, any Error>?
        /// What the download came to before its task completed: the file in place, or why it was refused.
        var outcome: Result<Void, any Error>?
    }

    private let destination: URL
    private let limit: Int64
    private let progress: @Sendable (Int64) -> Void
    private let state = Mutex(State())

    private init(destination: URL, limit: Int64, progress: @escaping @Sendable (Int64) -> Void) {
        self.destination = destination
        self.limit = limit
        self.progress = progress
    }

    /// Downloads `url` to `destination`, where nothing may be yet. `progress` hears the bytes received so far, on a
    /// queue of the session's. More than `limit` bytes are refused as soon as they are announced or arrive. Cancelling
    /// the calling task stops the download.
    static func file(_ url: URL, to destination: URL, limit: Int64, configuration: URLSessionConfiguration = UpdateCheck.configuration(),
                     progress: @escaping @Sendable (Int64) -> Void) async throws {
        let download = ReleaseDownload(destination: destination, limit: limit, progress: progress)
        let session = URLSession(configuration: configuration, delegate: download, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        request.setValue("Toolsy/\(ToolsyVersion.current)", forHTTPHeaderField: "User-Agent")
        // URLSession would send the user's preferred language.
        request.setValue("en", forHTTPHeaderField: "Accept-Language")
        request.httpShouldHandleCookies = false
        let task = session.downloadTask(with: request)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                download.state.withLock { $0.continuation = continuation }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesWritten <= limit, totalBytesExpectedToWrite <= limit else {
            let announced = max(totalBytesWritten, totalBytesExpectedToWrite)
            refuse(downloadTask, UpdateInstallError.unverified("\(announced) bytes came for a file of at most \(limit)"))
            return
        }
        progress(totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        let outcome: Result<Void, any Error> = if status == 200 {
            // The file at `location` is deleted when this method returns.
            Result { try FileManager.default.moveItem(at: location, to: destination) }
        } else {
            .failure(UpdateInstallError.unavailable("HTTP status \(status) for \(downloadTask.originalRequest?.url?.lastPathComponent ?? "a file")"))
        }
        state.withLock { if $0.outcome == nil { $0.outcome = outcome } }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let (continuation, result) = state.withLock { state in
            defer { state.continuation = nil }
            let result: Result<Void, any Error> = state.outcome ?? .failure(error ?? UpdateInstallError.unavailable("nothing arrived"))
            return (state.continuation, result)
        }
        continuation?.resume(with: result)
    }

    private func refuse(_ task: URLSessionTask, _ error: UpdateInstallError) {
        state.withLock { if $0.outcome == nil { $0.outcome = .failure(error) } }
        task.cancel()
    }
}
