#if DEBUG
import CryptoKit
import Foundation

/// A release served from a folder instead of GitHub (`--update-feed`), so that installing an update can be tried end
/// to end without publishing anything: GitHub's answer in `release.json`, the files it names lying next to it under
/// their names, and the public half of the key that signed them, base64, in `update-public-key`. A file arrives in ten
/// steps a fifth of a second apart, so the progress can be watched.
enum DebugUpdateFeed {
    static func fetch(_ folder: URL) -> () async throws -> (Data, URLResponse) {
        {
            let data = try Data(contentsOf: folder.appending(path: "release.json"))
            return (data, HTTPURLResponse(url: UpdateCheck.endpoint, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }

    static func key(_ folder: URL) -> Curve25519.Signing.PublicKey? {
        let file = folder.appending(path: "update-public-key")
        do {
            let text = try String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let raw = Data(base64Encoded: text) else { throw CocoaError(.fileReadCorruptFile) }
            return try Curve25519.Signing.PublicKey(rawRepresentation: raw)
        } catch {
            FileHandle.standardError.write(Data("Toolsy: \(file.path(percentEncoded: false)) holds no public key: \(error)\n".utf8))
            return nil
        }
    }

    static func download(_ folder: URL) -> @Sendable (URL, URL, Int64, @escaping @Sendable (Int64) -> Void) async throws -> Void {
        { url, destination, limit, progress in
            let data = try Data(contentsOf: folder.appending(path: url.lastPathComponent))
            guard Int64(data.count) <= limit else {
                throw UpdateInstallError.unverified("\(data.count) bytes came for a file of at most \(limit)")
            }
            for step in 1...10 {
                try await Task.sleep(for: .milliseconds(200))
                progress(Int64(data.count) * Int64(step) / 10)
            }
            try data.write(to: destination, options: .withoutOverwriting)
        }
    }
}
#endif
