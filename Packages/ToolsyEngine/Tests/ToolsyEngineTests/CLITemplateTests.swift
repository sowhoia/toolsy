import Foundation
import Testing
@testable import ToolsyEngine
import ToolsyShared

/// The templates of `toolsy-mod new`, end to end: written, validated without warnings, every command run
/// the way Toolsy runs it and producing a valid patch, packed, and the package validated.
@Suite struct CLITemplateTests {
    /// Writes the template into a new temporary folder and checks what `new` printed.
    private func make(_ template: String, id: String = "demo", in directory: TemporaryDirectory) async throws -> String {
        let result = try await toolsyMod(["new", id, "--template", template], in: directory.url)
        let folder = directory.url.appending(path: id).path(percentEncoded: false)
        #expect(result.status == 0 && result.error.isEmpty, "\(result.error)")
        // The tool names the folder by its physical path: /private/var for /var.
        #expect(result.output.hasPrefix("OK \(id) /") && result.output.contains("/\(id)\n  mod.json\n"), "\(result.output)")
        #expect(try await toolsyMod(["validate", folder]) == (0, "OK \(id) 1.0.0\n", ""), "valid, and without warnings")
        let readme = try String(contentsOf: directory.url.appending(path: "\(id)/README.md"), encoding: .utf8)
        #expect(readme.contains("toolsy-mod validate .") && readme.contains("toolsy-mod pack . -o ../\(id).toolsymod"))
        return folder
    }

    /// `run --json` of one command, which must succeed with a patch.
    private func patch(_ folder: String, _ command: String, _ options: [String] = []) async throws -> RunJSON {
        let result = try await toolsyModRun([folder, command, "--locale", "en", "--json"] + options)
        #expect(result.status == 0, "\(command): \(result.output)")
        let report = try JSONDecoder().decode(RunJSON.self, from: Data(result.output.utf8))
        #expect(report.ok && report.output?.kind == "patch" && report.notes.isEmpty, "\(command): \(result.output)")
        return report
    }

    /// Packing gives a package that validates as the folder did.
    private func packs(_ folder: String, id: String = "demo", in directory: TemporaryDirectory) async throws {
        let archive = directory.url.appending(path: "\(id).toolsymod").path(percentEncoded: false)
        #expect(try await toolsyMod(["pack", folder, "-o", archive]).status == 0)
        #expect(try await toolsyMod(["validate", archive]) == (0, "OK \(id) 1.0.0\n", ""))
    }

    @Test func basic() async throws {
        let directory = try TemporaryDirectory()
        let folder = try await make("basic", in: directory)
        let report = try await patch(folder, "check")
        let patch = try #require(report.output?.patch)
        #expect(Set(patch.keys) == ["uptime", "bootedAt", "status", "level"])
        #expect(patch["uptime"]?.numberValue.map { $0 > 0 } == true && patch["level"] == "ok" && patch["status"] == "Fine")
        // One day as the limit: a Mac that has run longer gets the warning, in the user's language.
        let strict = try await toolsyModRun([folder, "check", "--key", "days", "--value", "0", "--locale", "ru", "--json"])
        let warned = try JSONDecoder().decode(RunJSON.self, from: Data(strict.output.utf8))
        #expect(warned.output?.patch?["status"] == "Пора перезагрузить" && warned.output?.patch?["level"] == "warn")
        #expect(warned.notes == [#"an input binds "days", so its value was stored in the state first, as the control does"#])
        try await packs(folder, in: directory)
    }

    @Test func `switch`() async throws {
        let directory = try TemporaryDirectory()
        let folder = try await make("switch", in: directory)
        // Without a folder, switching on fails with a reason and changes nothing.
        let refused = try await toolsyModRun([folder, "hide", "--locale", "en", "--json"])
        #expect(refused.status == 1)
        #expect(try JSONDecoder().decode(RunJSON.self, from: Data(refused.output.utf8)).error == "Choose a folder first")
        #expect(try await patch(folder, "status").output?.patch == ["enabled": false, "status": "No folder chosen", "level": "off"])

        // A name that needs escaping in JSON.
        let target = directory.url.appending(path: #"We"ird\name"#, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let state = try String(decoding: JSONEncoder().encode(["folder": target.path(percentEncoded: false)]), as: UTF8.self)
        #expect(try await patch(folder, "hide", ["--state", state]).output?.patch
            == ["enabled": true, "status": #"Hidden: We"ird\name"#, "level": "ok"])
        #expect(try isHidden(target))
        #expect(try await patch(folder, "status", ["--state", state]).output?.patch?["enabled"] == true, "refresh reports the truth")
        #expect(try await patch(folder, "show", ["--state", state]).output?.patch == ["enabled": false, "status": "Visible", "level": "off"])
        #expect(try !isHidden(target))
        #expect(try await patch(folder, "status", ["--state", state]).output?.patch?["enabled"] == false)
        try await packs(folder, in: directory)
    }

    /// Read afresh each time: a URL caches the resource values it has read.
    private func isHidden(_ folder: URL) throws -> Bool {
        try URL(filePath: folder.path(percentEncoded: false)).resourceValues(forKeys: [.isHiddenKey]).isHidden == true
    }

    @Test func service() async throws {
        let directory = try TemporaryDirectory()
        let folder = try await make("service", in: directory)
        let result = try await toolsyModRun([folder, "watch", "--for", "4", "--state", #"{"interval": 1}"#, "--locale", "en", "--json"])
        #expect(result.status == 0, "\(result.output)")
        let report = try JSONDecoder().decode(RunJSON.self, from: Data(result.output.utf8))
        #expect(report.ok && report.service && report.timedOut && report.event == "service" && report.notes.isEmpty, "stopped while running")
        let lines = try #require(report.lines)
        #expect(!lines.isEmpty)
        for line in lines {
            #expect(line.kind == "patch")
            #expect(line.patch?["load"]?.numberValue != nil && line.patch?["cores"]?.numberValue != nil)
            #expect(["ok", "warn"].contains(line.patch?["level"]?.stringValue))
        }
        try await packs(folder, in: directory)
    }

    @Test func widget() async throws {
        let directory = try TemporaryDirectory()
        let folder = try await make("widget", in: directory)
        // The Mac running the tests may or may not have a battery; both are reported as a valid patch.
        let read = try #require(try await patch(folder, "read", ["--event", "wake"]).output)
        #expect(Set(try #require(read.patch).keys) == ["percent", "remaining", "source", "status", "level"])
        #expect(read.patch?["percent"].map { $0 == .null || $0.numberValue != nil } == true)
        #expect(read.notification == nil)

        let changed = try #require(try await patch(folder, "changed", ["--event", "power"]).output)
        let notification = try #require(changed.notification)
        #expect(notification.title == "Demo" && notification.body.hasPrefix("Power source: "))
        let quiet = try await patch(folder, "changed", ["--event", "power", "--state", #"{"announce": false}"#])
        #expect(quiet.output?.notification == nil && quiet.output?.patch?["notify"] == nil)
        try await packs(folder, in: directory)
    }

    @Test func newRefusesToOverwriteAndKeepsTheName() async throws {
        let directory = try TemporaryDirectory()
        try directory.write("mine", to: "taken/file")
        let taken = try await toolsyMod(["new", "taken"], in: directory.url)
        #expect(taken.status == 1 && taken.error.hasSuffix("/taken already exists; choose another folder with -o\n"))
        #expect(try String(contentsOf: directory.url.appending(path: "taken/file"), encoding: .utf8) == "mine")

        let named = try await toolsyMod(["new", "taken", "-o", "elsewhere/x", "--name", #"My "first" \ mod"#], in: directory.url)
        #expect(named.status == 1 && named.error.hasSuffix("/elsewhere/ does not exist\n"))
        let made = try await toolsyMod(["new", "keep.awake", "-o", "other", "--name", #"My "first" \ mod"#], in: directory.url)
        #expect(made.status == 0)
        let manifest = try ModManifest.load(from: Data(contentsOf: directory.url.appending(path: "other/mod.json")))
        #expect(manifest.id == "keep.awake" && manifest.name == #"My "first" \ mod"#)
        #expect(try String(contentsOf: directory.url.appending(path: "other/README.md"), encoding: .utf8).hasPrefix(#"# My "first" \ mod"#))
        let entries = try FileManager.default.contentsOfDirectory(atPath: directory.url.path(percentEncoded: false)).sorted()
        #expect(entries == ["other", "taken"], "nothing half-written is left behind")

        #expect(try await toolsyMod(["new", "keep-awake"], in: directory.url).status == 0)
        #expect(try ModManifest.load(from: Data(contentsOf: directory.url.appending(path: "keep-awake/mod.json"))).name == "Keep awake")
        let scripts = try FileManager.default.attributesOfItem(atPath: directory.url.appending(path: "keep-awake/check.sh").path(percentEncoded: false))
        #expect(scripts[.posixPermissions] as? Int == 0o755)
    }
}
