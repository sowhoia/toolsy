import Foundation
import Testing
@testable import ToolsyEngine
import ToolsyShared

/// Quick controls are controls like those of the page: their templates and expressions are checked, their inputs
/// are warned about and bind state, and `preview` shows them.
@Suite struct QuickControlTests {
    private static let mod = #"""
        {
          "schema": 1, "id": "quick", "name": "Quick", "version": "1",
          "settings": { "display": false, "minutes": 60 },
          "commands": { "go": { "shell": "true" }, "retime": { "shell": "true" } },
          "lifecycle": { "enable": "go", "disable": "go" },
          "quick": [
            { "type": "button", "label": "Restart {{minutes}}", "icon": "arrow.clockwise", "command": "go", "confirm": "Restart now?" },
            { "type": "picker", "label": "For", "bind": "minutes", "command": "retime", "options": [ { "value": 30, "label": "30 min" }, { "value": 60, "label": "1 hour" } ] },
            { "type": "toggle", "label": "Display", "bind": "display", "when": "enabled" }
          ]
        }
        """#

    @Test func theirTemplatesAndExpressionsAreChecked() throws {
        func check(_ json: String) -> String {
            do {
                try ModManifest.load(from: Data(json.utf8)).validateTemplatesAndExpressions()
                return "no error"
            } catch {
                return error.localizedDescription
            }
        }
        #expect(check(Self.mod) == "no error")
        #expect(check(Self.mod.replacingOccurrences(of: "Restart {{minutes}}", with: "Restart {{minutes|shout}}"))
            == #"quick[0].label: unknown filter "shout""#)
        #expect(check(Self.mod.replacingOccurrences(of: #""when": "enabled""#, with: #""when": "(enabled""#))
            == #"quick[2].when: "(" is not closed"#)
    }

    /// `allControls` is what the engine and `toolsy-mod run` read binds from.
    @Test func theyAreAmongTheManifestsControls() throws {
        let manifest = try ModManifest.load(from: Data(Self.mod.utf8))
        #expect(manifest.allControls.count == 3)
    }

    @Test func aDefaultTheirInputCannotShowIsWarnedAbout() async throws {
        let directory = try TemporaryDirectory()
        let folder = try writeMod(Self.mod.replacingOccurrences(of: #""display": false"#, with: #""display": "no""#), in: directory)
        #expect(try await ModPackage.inspect(folder).warnings
            == [#"quick[2]: the default of setting "display", "no", is not true or false; the toggle shows it as off"#])
    }

    @Test func previewShowsThemAboveThePage() async throws {
        let directory = try TemporaryDirectory()
        let folder = try writeMod(Self.mod, in: directory)
        let result = try await toolsyMod(["preview", folder.path(percentEncoded: false), "--state", #"{"enabled": true}"#])
        #expect(result.status == 0)
        let lines = result.output.split(separator: "\n").map(String.init)
        let start = try #require(lines.firstIndex(of: "quick:"))
        #expect(lines.firstIndex(of: "page:").map { $0 > start } == true)
        #expect(lines[start + 1].hasPrefix(#"  button "Restart 60""#))
        #expect(lines.contains { $0.hasPrefix(#"  picker "For": "1 hour""#) })
        #expect(lines.contains { $0.hasPrefix(#"  toggle "Display": off"#) })
    }
}
