import CryptoKit
import Foundation
import Testing
import ToolsyShared
@testable import Toolsy

struct AppVersionTests {
    private func infoPlist() throws -> [String: Any] {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appending(path: "Resources/Info.plist"))
        return try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    /// The bundle and the shared code say the same version, so `toolsy-mod` and the app agree on it.
    @Test func infoPlistCarriesTheSharedVersion() throws {
        #expect(try infoPlist()["CFBundleShortVersionString"] as? String == ToolsyVersion.current)
    }

    /// Without the public half of the release key no update could be installed.
    @Test func infoPlistNamesTheReleaseKey() throws {
        let text = try #require(try infoPlist()[UpdateSignature.infoKey] as? String)
        let raw = try #require(Data(base64Encoded: text))
        #expect(throws: Never.self) { try Curve25519.Signing.PublicKey(rawRepresentation: raw) }
    }
}
