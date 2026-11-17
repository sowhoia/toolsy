import Foundation
import Testing
@testable import ToolsyEngine
import ToolsyShared

@Suite struct InspectionTests {
    private static let repository = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    private func warnings(_ extra: String, scripts: [String: String] = [:]) async throws -> [String] {
        let directory = try TemporaryDirectory()
        return try await ModPackage.inspect(writeMod(manifest(extra), scripts: scripts, in: directory)).warnings
    }

    @Test func aWellMadeModHasNoWarnings() async throws {
        let (manifest, warnings, _) = try await ModPackage.inspect(Self.repository.appending(path: "Mods/showcase"))
        #expect(manifest.id == "showcase")
        #expect(warnings == [])
    }

    @Test func inspectsLikeValidate() async throws {
        let directory = try TemporaryDirectory()
        let broken = try writeMod(manifest(#""ui": [{"type": "text", "text": "{{x|shout}}"}]"#), in: directory)
        await #expect(throws: ManifestError("ui[0].text: unknown filter \"shout\"")) { try await ModPackage.inspect(broken) }
        try directory.write(manifest(id: "lone", #""commands": {"go": {"shell": "./go.sh"}}"#), to: "lone.json")
        let lone = try await ModPackage.inspect(directory.url.appending(path: "lone.json"))
        #expect(lone.manifest.id == "lone")
        #expect(lone.warnings == [#"commands.go: shell starts with "./go.sh", which is not a file of the mod"#])
    }

    @Test func shellProgramsThatCannotStart() async throws {
        let commands = #"""
            "commands": {"missing": {"shell": "scripts/gone.sh now"}, "plain": {"shell": "./data.txt"}, "fine": {"shell": "./bin/run --flag"},
                         "system": {"shell": "/usr/bin/true"}, "word": {"shell": "echo hi"}, "variable": {"shell": "$TOOLSY_MOD_DIR/x"}},
            "lifecycle": {"events": {"launch": "missing", "wake": "plain", "network": "fine", "power": "system"}},
            "ui": [{"type": "button", "label": "W", "command": "word"}, {"type": "button", "label": "V", "command": "variable"}]
            """#
        let directory = try TemporaryDirectory()
        let folder = try writeMod(manifest(commands), scripts: ["bin/run": "true"], in: directory)
        try directory.write("x", to: "source/data.txt")
        #expect(try await ModPackage.inspect(folder).warnings == [
            #"commands.missing: shell starts with "scripts/gone.sh", which is not a file of the mod"#,
            #"commands.plain: shell starts with "./data.txt", which is not executable (chmod +x)"#,
        ])
    }

    @Test func settingDefaultsTheirInputsCannotShow() async throws {
        let ui = #"""
            "settings": {"on": "true", "amount": 150, "low": -1, "word": "5", "mode": 1, "tags": ["a"], "fine": true, "steps": 3, "choice": "b"},
            "ui": [
              {"type": "toggle", "label": "On", "bind": "on"},
              {"type": "slider", "label": "Amount", "bind": "amount", "min": 0, "max": 100},
              {"type": "row", "children": [{"type": "stepper", "label": "Low", "bind": "low", "min": 0}]},
              {"type": "slider", "label": "Word", "bind": "word", "min": 0, "max": 10},
              {"type": "picker", "bind": "mode", "options": ["1", "2"]},
              {"type": "input", "bind": "tags"},
              {"type": "toggle", "label": "Fine", "bind": "fine"},
              {"type": "stepper", "label": "Steps", "bind": "steps", "max": 5},
              {"type": "picker", "bind": "choice", "options": [{"value": "a"}, {"value": "b"}]},
              {"type": "picker", "bind": "mode", "optionsFrom": "modes"}
            ],
            "widgets": [{"id": "w", "value": "v", "detail": [{"type": "stepper", "label": "S", "bind": "amount", "max": 99}]}]
            """#
        #expect(try await warnings(ui) == [
            #"ui[0]: the default of setting "on", "true", is not true or false; the toggle shows it as off"#,
            #"ui[1]: the default of setting "amount", 150, is above the slider's max 100"#,
            #"ui[2].children[0]: the default of setting "low", -1, is below the stepper's min 0"#,
            #"ui[3]: the default of setting "word", "5", is not a number; the slider shows its minimum"#,
            #"ui[4]: the default of setting "mode", 1, matches the value of none of the options ("1", "2"); the picker shows nothing selected"#,
            #"ui[5]: the default of setting "tags", ["a"], is not text, a number or a boolean; the field shows nothing"#,
            #"widgets[0].detail[0]: the default of setting "amount", 150, is above the stepper's max 99"#,
        ])
    }

    @Test func translationsNothingUses() async throws {
        let localized = #"""
            "summary": "Sum", "settings": {"x": 1},
            "ui": [{"type": "picker", "label": "Pick", "bind": "x", "options": [{"value": 1, "label": "One"}]},
                   {"type": "button", "label": "Go", "open": "https://example.com", "confirm": "Sure?", "help": "Tip"}],
            "widgets": [{"id": "w", "value": "{{x}} ms", "chart": {"series": [{"bind": "x", "label": "Series"}]}}],
            "localizations": {
              "ru": {"Demo": "Демо", "Sum": "Итог", "Pick": "Выбор", "One": "Один", "Go": "Вперёд", "Sure?": "Точно?", "Tip": "Совет",
                     "{{x}} ms": "{{x}} мс", "Series": "Ряд", "Gone": "Нет", "x": "икс", "https://example.com": "https://example.ru"},
              "de": {"Demo": "Demo", "Pick ": "Wahl"}
            }
            """#
        #expect(try await warnings(localized) == [
            #"localizations.de: "Pick " is not the text of any translated field, so this entry is never used"#,
            #"localizations.ru: "Gone" is not the text of any translated field, so this entry is never used"#,
            #"localizations.ru: "https://example.com" is not the text of any translated field, so this entry is never used"#,
            #"localizations.ru: "x" is not the text of any translated field, so this entry is never used"#,
        ])
    }
}
