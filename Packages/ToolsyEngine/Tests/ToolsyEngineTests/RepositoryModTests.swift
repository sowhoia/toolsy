import Foundation
import Testing
@testable import ToolsyEngine
@testable import ToolsyShared

/// The mods in Mods/ are what a new user installs first and what mod authors copy, so each one must pass
/// the checks installing it runs and must translate all of its text.
@Suite struct RepositoryModTests {
    private static let modsFolder = DocumentedManifestTests.repository.appending(path: "Mods", directoryHint: .isDirectory)

    /// Folders of Mods/ that hold a manifest. An unreadable folder yields none, which `everyModIsTested` reports.
    static let mods: [String] = {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: modsFolder.path(percentEncoded: false))) ?? []
        return names.filter { FileManager.default.fileExists(atPath: folder($0).appending(path: ModManifest.fileName).path(percentEncoded: false)) }.sorted()
    }()

    /// Mods whose manifest is written in Russian, without translations.
    private static let writtenInRussian: Set = ["vpn-protector"]

    private static func folder(_ name: String) -> URL {
        modsFolder.appending(path: name, directoryHint: .isDirectory)
    }

    private static func manifest(of name: String) throws -> ModManifest {
        try ModManifest.load(from: Data(contentsOf: folder(name).appending(path: ModManifest.fileName)))
    }

    @Test func everyModIsTested() {
        #expect(Set(["keep-awake", "network-info", "showcase", "timer", "vpn-protector"]).isSubset(of: Self.mods), "\(Self.mods)")
    }

    /// A mod of scripts is checked as a folder exactly as installing checks a package. A mod built from Swift
    /// sources (it has a Package.swift) has its program only after its build.sh, so here only its manifest is
    /// checked; scripts/build-mods.sh validates the package it builds.
    @Test(arguments: mods)
    func passesTheChecksOfInstalling(_ name: String) async throws {
        let compiled = FileManager.default.fileExists(atPath: Self.folder(name).appending(path: "Package.swift").path(percentEncoded: false))
        let manifest: ModManifest
        if compiled {
            manifest = try Self.manifest(of: name)
            try manifest.validateTemplatesAndExpressions()
        } else {
            manifest = try await ModPackage.validate(Self.folder(name))
        }
        #expect(manifest.id == name, "the folder is named after the mod")
    }

    /// Every text the user sees has a translation in each language the mod offers, every translation keeps
    /// the placeholders of its source, and no translation is left over from text that is gone.
    @Test(arguments: mods)
    func translatesAllOfItsText(_ name: String) throws {
        let manifest = try Self.manifest(of: name)
        #expect(manifest.localizations["ru"] != nil || Self.writtenInRussian.contains(name), "\(name) has no Russian translation")

        var texts: Set = [manifest.name]
        if let summary = manifest.summary { texts.insert(summary) }
        func collect(_ text: String) -> String {
            texts.insert(text)
            return text
        }
        _ = manifest.ui.map { $0.translated(with: collect) }
        _ = manifest.widgets.map { $0.translated(with: collect) }

        for (code, table) in manifest.localizations {
            let missing = texts.filter { Self.needsTranslation($0) && table[$0] == nil }.sorted()
            #expect(missing.isEmpty, "\(name): no \(code) translation of \(missing)")
            let unused = Set(table.keys).subtracting(texts).sorted()
            #expect(unused.isEmpty, "\(name): \(code) translates text the manifest does not have: \(unused)")
            for (source, translation) in table {
                #expect(Self.placeholders(source) == Self.placeholders(translation), "\(name): \(code) translation of \"\(source)\"")
            }
        }
    }

    /// Toolsy's `PATH` searches Homebrew's folders first, so a bare `jq` may run another version the user installed;
    /// MOD_AUTHORING_FOR_AI.md requires `/usr/bin/jq`, and mod authors copy these mods. Comments may name it.
    @Test func callsJqByItsAbsolutePath() throws {
        var sources: [(place: String, code: String)] = []
        let files = try #require(FileManager.default.enumerator(
            at: Self.modsFolder, includingPropertiesForKeys: [.isRegularFileKey], options: .skipsHiddenFiles
        ))
        for case let file as URL in files {
            // What build.sh stages and packs is a copy, possibly of an older version.
            if file.lastPathComponent == "build" {
                files.skipDescendants()
                continue
            }
            guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true,
                  let text = try? String(contentsOf: file, encoding: .utf8),
                  file.pathExtension == "sh" || text.hasPrefix("#!/bin/sh") || text.hasPrefix("#!/bin/bash") else { continue }
            sources.append((file.path(percentEncoded: false), text))
        }
        for name in Self.mods {
            for (command, definition) in try Self.manifest(of: name).commands {
                if case .shell(let script) = definition.program {
                    sources.append(("\(name)/mod.json commands.\(command).shell", script))
                }
            }
        }
        #expect(sources.count > 10, "\(sources.map(\.place))")
        for (place, code) in sources {
            for (index, line) in code.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let statement = line.replacing(/(^|\s)#.*/, with: "")
                // `jq` as a word of its own: not /usr/bin/jq, $jq, ${jq}, jq=, patch.jq.
                #expect(!statement.contains(/(^|[^\w\/.${-])jq([^\w.=-]|$)/), "\(place):\(index + 1) calls jq by name: \(line)")
            }
        }
    }

    /// Whether a text reads differently in another language: what it shows of its own (the text around its
    /// placeholders and the texts of `default`, `either` and `join`) has two lowercase letters in a row.
    /// `IPv4`, `DNS` or `{{ip}}` read the same everywhere.
    static func needsTranslation(_ text: String) -> Bool {
        var shown = text.replacing(/\{\{[^}]*\}\}/, with: " ")
        for match in text.matches(of: /\|\s*(?:default|either|join)\s*:([^|}]*)/) {
            shown += " " + match.1
        }
        return shown.contains(/\p{Ll}\p{Ll}/)
    }

    /// The state paths a template shows, sorted: `{{ms|fixed:1}} ms` → `["ms"]`.
    static func placeholders(_ text: String) -> [String] {
        text.matches(of: /\{\{\s*([^|}\s]*)/).map { String($0.1) }.sorted()
    }

    @Test func textNeedsTranslationOnlyWhereItShowsWords() {
        #expect(Self.needsTranslation("Keep the display on"))
        #expect(Self.needsTranslation("{{ms}} ms"))
        #expect(Self.needsTranslation("{{address|default:Offline}}"))
        #expect(Self.needsTranslation("{{display|either:On:Off}}"))
        #expect(!Self.needsTranslation("{{ip|default:—}}"))
        #expect(!Self.needsTranslation("IPv4"))
        #expect(!Self.needsTranslation("{{dns|join}} · DNS"))
        #expect(Self.placeholders("{{a}} of {{ b.0|fixed:1 }} {{a|default:x}}") == ["a", "a", "b.0"])
    }
}
