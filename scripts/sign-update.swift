// Signs the archive of a release for Toolsy's own updater, with a key made by `toolsy-mod keygen`.
//
//   swift scripts/sign-update.swift <key> <version> <archive>   writes <archive>.sig
//   swift scripts/sign-update.swift --check <key>                checks that Resources/Info.plist trusts <key>
//   swift scripts/sign-update.swift --public-key <key>           prints the public half, for ToolsyUpdatePublicKey
//
// The signature covers the version, the archive's size and its SHA-256; UpdateSignature in
// Sources/Toolsy/App/UpdateInstaller.swift checks it with the public key in ToolsyUpdatePublicKey of Resources/Info.plist.
// Signing refuses a key that is not that one, since Toolsy would refuse everything it signs.
import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("sign-update: \(message)\n".utf8))
    exit(1)
}

let usage = "usage: sign-update.swift <key> <version> <archive> | --check <key> | --public-key <key>"
let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

/// A key as `toolsy-mod keygen` writes it.
func privateKey(at path: String) -> Curve25519.Signing.PrivateKey {
    struct File: Decodable {
        var toolsySigningKey: Int
        var privateKey: String
    }
    guard let data = FileManager.default.contents(atPath: path) else { fail("cannot read \(path)") }
    guard let file = try? JSONDecoder().decode(File.self, from: data), file.toolsySigningKey == 1,
          let raw = Data(base64Encoded: file.privateKey), let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
        fail("\(path) is not a key made by toolsy-mod keygen")
    }
    return key
}

/// What people compare, as `toolsy-mod` shows it: the first 8 bytes of the key's SHA-256.
func fingerprint(_ key: Curve25519.Signing.PublicKey) -> String {
    let hex = SHA256.hash(data: key.rawRepresentation).prefix(8).map { String(format: "%02X", $0) }.joined()
    return stride(from: 0, to: hex.count, by: 4).map { String(hex.dropFirst($0).prefix(4)) }.joined(separator: " ")
}

func checkTrusted(_ key: Curve25519.Signing.PrivateKey, path: String) {
    let plist = root.appending(path: "Resources/Info.plist")
    guard let data = try? Data(contentsOf: plist),
          let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
          let trusted = info["ToolsyUpdatePublicKey"] as? String else {
        fail("\(plist.path) has no ToolsyUpdatePublicKey")
    }
    guard trusted == key.publicKey.rawRepresentation.base64EncodedString() else {
        fail("\(path) (key \(fingerprint(key.publicKey))) is not the key ToolsyUpdatePublicKey in Resources/Info.plist names; Toolsy would refuse what it signs")
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "--public-key" where arguments.count == 2:
    print(privateKey(at: arguments[1]).publicKey.rawRepresentation.base64EncodedString())
case "--check" where arguments.count == 2:
    let key = privateKey(at: arguments[1])
    checkTrusted(key, path: arguments[1])
    print("key \(fingerprint(key.publicKey)) is the one Toolsy trusts")
case .some where arguments.count == 3 && !arguments[0].hasPrefix("--"):
    let (keyPath, version, archivePath) = (arguments[0], arguments[1], arguments[2])
    guard version.wholeMatch(of: #/[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?/#) != nil else {
        fail("\(version) is not a version such as 1.2.0")
    }
    let key = privateKey(at: keyPath)
    checkTrusted(key, path: keyPath)
    let archive = URL(filePath: archivePath)
    guard let data = try? Data(contentsOf: archive, options: .alwaysMapped), !data.isEmpty else { fail("cannot read \(archivePath)") }
    let sha256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    // UpdateSignature.message(version:size:sha256:) in the app.
    let message = Data("toolsy update signature 1\n\(version)\n\(data.count)\n\(sha256)".utf8)
    let signature: Data
    do {
        signature = try key.signature(for: message)
    } catch {
        fail("cannot sign: \(error.localizedDescription)")
    }
    struct SignatureFile: Encodable {
        var format = 1
        var version: String
        var size: Int
        var sha256: String
        var signature: String
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    let file = SignatureFile(version: version, size: data.count, sha256: sha256, signature: signature.base64EncodedString())
    let destination = archive.deletingLastPathComponent().appending(path: archive.lastPathComponent + ".sig")
    do {
        try encoder.encode(file).write(to: destination, options: .atomic)
    } catch {
        fail("cannot write \(destination.path): \(error.localizedDescription)")
    }
    print("signed \(archive.lastPathComponent) with key \(fingerprint(key.publicKey))")
default:
    fail(usage)
}
