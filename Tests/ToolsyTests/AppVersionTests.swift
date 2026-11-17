import Foundation
import Testing
import ToolsyShared

struct AppVersionTests {
    /// The bundle and the shared code say the same version, so `toolsy-mod` and the app agree on it.
    @Test func infoPlistCarriesTheSharedVersion() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appending(path: "Resources/Info.plist"))
        let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(plist["CFBundleShortVersionString"] as? String == ToolsyVersion.current)
    }
}
