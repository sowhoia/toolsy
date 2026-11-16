import Foundation
import Testing
@testable import ToolsyEngine
import ToolsyShared

/// A Markdown document of the repository, read as a test reads it: its fenced code blocks and its sections.
struct Documentation {
    /// A fenced block: ```` ```<language> [<path>] ````, its body up to the closing fence.
    struct Block {
        let language: String
        /// The file the block reproduces, as written after the language: `uptime/mod.json`.
        let path: String?
        let body: String
    }

    static let formatSpecification = "docs/MOD_FORMAT.md"
    static let authoringSpecification = "docs/MOD_AUTHORING_FOR_AI.md"

    let text: String

    init(_ relativePath: String) throws {
        text = try String(contentsOf: DocumentedManifestTests.repository.appending(path: relativePath), encoding: .utf8)
    }

    var blocks: [Block] {
        text.matches(of: /(?m)^```(?<language>\S*)(?: (?<path>\S+))?\n(?<body>(?:.|\n)*?)^```$/).map {
            Block(language: String($0.language), path: $0.path.map(String.init), body: String($0.body))
        }
    }

    /// Fenced `json` blocks that are whole manifests (they declare `"schema"`).
    var manifests: [String] {
        blocks.filter { $0.language == "json" && $0.body.contains(#""schema""#) }.map(\.body)
    }

    /// The text under the heading `title` (any level) up to the next heading of the same or a higher level.
    func section(_ title: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        // The heading level of each line; nil for text and for every line of a fenced block (shell comments).
        var inBlock = false
        let levels = lines.map { line -> Int? in
            if line.hasPrefix("```") { inBlock.toggle() }
            let hashes = line.prefix { $0 == "#" }.count
            return !inBlock && hashes > 0 && line.dropFirst(hashes).hasPrefix(" ") ? hashes : nil
        }
        guard let start = lines.indices.first(where: { levels[$0] != nil && lines[$0].drop { $0 == "#" } == " \(title)" }),
              let depth = levels[start] else { return "" }
        let end = levels[(start + 1)...].firstIndex { $0.map { $0 <= depth } ?? false } ?? lines.endIndex
        return lines[start..<end].joined(separator: "\n")
    }
}

/// The documentation is part of the contract: every complete manifest it shows must be valid, every shell
/// example must parse, and so must the mods maintained in this repository.
@Suite struct DocumentedManifestTests {
    static let repository = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    @Test(arguments: [Documentation.formatSpecification, Documentation.authoringSpecification])
    func everyDocumentedManifestIsValid(_ document: String) throws {
        let manifests = try Documentation(document).manifests
        #expect(manifests.count >= 4)
        for manifest in manifests {
            #expect(throws: Never.self, "\(manifest)") {
                try ModManifest.load(from: Data(manifest.utf8)).validateTemplatesAndExpressions()
            }
        }
    }

    /// `sh -n` reads a script without running it: every `sh` block, whole scripts and fragments alike, parses.
    @Test(arguments: [Documentation.formatSpecification, Documentation.authoringSpecification])
    func everyShellExampleParses(_ document: String) async throws {
        let scripts = try Documentation(document).blocks.filter { $0.language == "sh" }
        #expect(!scripts.isEmpty)
        for script in scripts {
            let result = try await ProcessRunner.run(ProcessRunner.Request(
                executable: URL(filePath: "/bin/sh"), arguments: ["-n"], stdin: Data(script.body.utf8)
            ))
            #expect(result.succeeded, "\(String(decoding: result.stderr, as: UTF8.self))\n\(script.body)")
        }
    }

    @Test(arguments: ["vpn-protector"])
    func repositoryModsStayValidAndUnchanged(_ id: String) throws {
        let data = try Data(contentsOf: Self.repository.appending(path: "Mods/\(id)/mod.json"))
        let manifest = try ModManifest.load(from: data)
        try manifest.validateTemplatesAndExpressions()
        #expect(manifest.id == id)
        #expect(manifest.widgets.isEmpty && manifest.localizations.isEmpty && manifest.lifecycle.events.isEmpty)
        #expect(manifest.localized(for: ["ru-RU", "en"]) == manifest)
    }
}
