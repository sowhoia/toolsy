import Foundation
import Testing
@testable import ToolsyEngine
import ToolsyShared

/// The documentation is part of the contract: every complete manifest it shows must be valid, and so must
/// the mods maintained in this repository.
@Suite struct DocumentedManifestTests {
    private static let repository = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    /// Fenced ```json blocks of docs/MOD_FORMAT.md that are whole manifests (they declare `"schema"`).
    private static func documentedManifests() throws -> [String] {
        let text = try String(contentsOf: repository.appending(path: "docs/MOD_FORMAT.md"), encoding: .utf8)
        return text.matches(of: /```json\n(?<body>(?:.|\n)*?)```/).map { String($0.body) }.filter { $0.contains(#""schema""#) }
    }

    @Test func everyDocumentedManifestIsValid() throws {
        let manifests = try Self.documentedManifests()
        #expect(manifests.count >= 4)
        for manifest in manifests {
            #expect(throws: Never.self, "\(manifest)") {
                try ModManifest.load(from: Data(manifest.utf8)).validateTemplatesAndExpressions()
            }
        }
    }

    @Test(arguments: ["showcase", "vpn-protector"])
    func repositoryModsStayValidAndUnchanged(_ id: String) throws {
        let data = try Data(contentsOf: Self.repository.appending(path: "Mods/\(id)/mod.json"))
        let manifest = try ModManifest.load(from: data)
        try manifest.validateTemplatesAndExpressions()
        #expect(manifest.id == id)
        #expect(manifest.widgets.isEmpty && manifest.localizations.isEmpty && manifest.lifecycle.events.isEmpty)
        #expect(manifest.localized(for: ["ru-RU", "en"]) == manifest)
    }
}
