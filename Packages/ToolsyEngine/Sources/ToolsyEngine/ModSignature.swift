import CryptoKit
import Foundation
import ToolsyShared

/// The signature of a `.toolsymod` file: an Ed25519 key vouching for exactly its files (MOD_FORMAT.md,
/// "Signing"). It lies in the archive as `.toolsy-signature`, beside the mod rather than in it: it is not
/// installed and not part of the digest it signs.
public struct ModSignature: Sendable, Equatable {
    public static let fileName = ".toolsy-signature"
    /// Far more than the JSON of a key and a signature.
    static let maxFileSize = 4096

    /// The public half of the signing key, 32 bytes.
    public let publicKey: Data

    public init(publicKey: Data) {
        self.publicKey = publicKey
    }

    /// What people compare: the first 8 bytes of the key's SHA-256, as "7F3A 9C21 44B0 E1D2".
    public var fingerprint: String {
        let hex = SHA256.hash(data: publicKey).prefix(8).map { String(format: "%02X", $0) }.joined()
        return stride(from: 0, to: hex.count, by: 4).map { start in
            String(hex.dropFirst(start).prefix(4))
        }.joined(separator: " ")
    }

    private struct File: Codable {
        var format: Int
        var key: String
        var signature: String
    }

    /// The bytes signed for a payload: its digest, under a label of its own so that the signature vouches for
    /// nothing else.
    private static func message(digest: String) -> Data {
        Data("toolsy mod signature 1\n\(digest)".utf8)
    }

    /// Checks a signature file against the digest of the files it came with.
    static func verify(_ file: Data, digest: String) throws -> ModSignature {
        guard file.count <= maxFileSize, let decoded = try? JSONValue.decode(File.self, from: file), decoded.format == 1,
              let key = Data(base64Encoded: decoded.key), let signature = Data(base64Encoded: decoded.signature),
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: key) else {
            throw EngineError("\(fileName) is not a signature this version of Toolsy can read")
        }
        guard publicKey.isValidSignature(signature, for: message(digest: digest)) else {
            throw EngineError("the signature does not match the files: the package was changed after it was signed")
        }
        return ModSignature(publicKey: key)
    }

    /// The signature file for a payload with `digest`.
    static func file(signing digest: String, with key: Curve25519.Signing.PrivateKey) throws -> Data {
        let file = File(
            format: 1,
            key: key.publicKey.rawRepresentation.base64EncodedString(),
            signature: try key.signature(for: message(digest: digest)).base64EncodedString()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(file)
    }
}

/// A signing key as `toolsy-mod keygen` writes it: JSON with the private half, readable by its owner only.
public enum ModSigningKey {
    private struct File: Codable {
        var toolsySigningKey: Int
        var privateKey: String
    }

    /// Writes a new key to `url`, which must not exist yet, and returns its public half.
    public static func generate(at url: URL) throws -> ModSignature {
        let key = Curve25519.Signing.PrivateKey()
        let data = try JSONEncoder().encode(File(toolsySigningKey: 1, privateKey: key.rawRepresentation.base64EncodedString()))
        let path = url.path(percentEncoded: false)
        // Created owner-only and never over an existing file: losing a key cannot be undone.
        let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw EngineError(errno == EEXIST ? "\(url.lastPathComponent) already exists" : "cannot create \(path): \(String(cString: strerror(errno)))")
        }
        defer { close(descriptor) }
        let written = data.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
        guard written == data.count else {
            throw EngineError("cannot write \(path): \(String(cString: strerror(errno)))")
        }
        return ModSignature(publicKey: key.publicKey.rawRepresentation)
    }

    public static func load(from url: URL) throws -> Curve25519.Signing.PrivateKey {
        guard let data = try? Data(contentsOf: url), let file = try? JSONDecoder().decode(File.self, from: data),
              file.toolsySigningKey == 1, let raw = Data(base64Encoded: file.privateKey),
              let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
            throw EngineError("\(url.lastPathComponent) is not a signing key written by toolsy-mod keygen")
        }
        return key
    }
}
