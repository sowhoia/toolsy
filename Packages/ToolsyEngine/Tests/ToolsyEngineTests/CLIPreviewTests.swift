import Foundation
import Testing
@testable import ToolsyEngine
import ToolsyShared

/// `preview` prints a stable outline; these snapshots cover every control type, the markers and the widgets.
@Suite struct CLIPreviewTests {
    /// Every control type, nested sections and rows, `when` and `disabled`, both widget visuals and a
    /// localization table. No filter depends on the locale or the clock, so the outline is the same everywhere.
    private static let everyControl = #"""
            {
              "schema": 1, "id": "every", "name": "Every control", "version": "3.1", "tint": "teal",
              "settings": { "on": true, "volume": 40, "count": 2, "mode": "b", "host": "example.com", "shape": "x" },
              "commands": { "go": { "shell": "true" }, "watch": { "shell": "sleep 9" } },
              "lifecycle": { "service": "watch" },
              "ui": [
                { "type": "section", "title": "Inputs {{count}}", "footer": "Changed {{count}} times", "children": [
                  { "type": "toggle", "label": "Enabled thing", "bind": "on", "command": "go", "help": "Turns it on" },
                  { "type": "slider", "label": "Volume", "bind": "volume", "min": 0, "max": 100, "step": 5, "unit": "%", "live": true, "command": "go" },
                  { "type": "stepper", "label": "Count", "bind": "count", "min": 1, "unit": " times" },
                  { "type": "stepper", "label": "Missing", "bind": "absent", "max": -2 },
                  { "type": "picker", "label": "Mode", "bind": "mode", "options": ["a", { "value": "b", "label": "Bee" }, { "value": 3, "label": "Three" }] },
                  { "type": "picker", "bind": "shape", "optionsFrom": "shapes", "style": "menu" },
                  { "type": "input", "label": "Host", "bind": "host", "placeholder": "name", "command": "go", "disabled": "!enabled" }
                ] },
                { "type": "section", "title": "More", "collapsible": true, "collapsed": true, "children": [
                  { "type": "row", "children": [
                    { "type": "stat", "label": "Load", "value": "{{load|fixed:1|default:—}}", "tint": "{{level}}" },
                    { "type": "stat", "label": "Hidden", "value": "x", "when": "load > 100" }
                  ] },
                  { "type": "row", "when": "enabled", "children": [ { "type": "text", "text": "never", "when": "false" } ] }
                ] },
                { "type": "divider" },
                { "type": "button", "label": "Go {{host}}", "command": "go", "value": 7, "style": "destructive", "confirm": "Really?" },
                { "type": "button", "label": "Docs", "open": "https://example.com/docs" },
                { "type": "button", "label": "Copy", "copy": "{{host}}:{{count}}", "when": "host" },
                { "type": "value", "label": "Status", "value": "{{status|default:none}}", "tint": "purplish", "copyable": true },
                { "type": "text", "text": "{{rows|count}} rows", "style": "mono" },
                { "type": "gauge", "label": "Load", "bind": "load", "max": 8, "format": "fixed:2", "style": "ring", "tint": "#FF8800" },
                { "type": "gauge", "label": "Empty", "bind": "nothing", "unit": "%" },
                { "type": "chart", "label": "History", "series": [ { "bind": "load", "label": "Load", "tint": "orange" }, { "bind": "samples" }, { "bind": "status" } ], "style": "bar", "points": 30, "min": 0, "unit": " ms" },
                { "type": "list", "bind": "rows", "command": "go", "limit": 2, "empty": "Nothing yet" },
                { "type": "list", "bind": "none", "empty": "Nothing yet" }
              ],
              "widgets": [
                { "id": "load", "title": "Load {{load}}", "value": "{{load|fixed:1}}", "tint": "{{level}}", "size": "medium",
                  "chart": { "series": [ { "bind": "samples" } ], "points": 20, "max": 10 },
                  "detail": [ { "type": "value", "label": "Now", "value": "{{load}}" } ] },
                { "id": "gauge", "value": "{{volume}}%", "gauge": { "bind": "volume", "min": 0, "max": 200 }, "when": "!enabled" }
              ],
              "localizations": { "ru": { "Every control": "Все элементы", "Volume": "Громкость", "Bee": "Пчела", "Nothing yet": "Пока пусто" } }
            }
            """#

    private func preview(_ arguments: [String]) async throws -> (status: Int32, output: String, error: String) {
        let directory = try TemporaryDirectory()
        let folder = try writeMod(Self.everyControl, in: directory)
        return try await toolsyMod(["preview", folder.path(percentEncoded: false)] + arguments)
    }

    @Test func outlinesALiveState() async throws {
        let state = #"{"enabled": true, "load": 2.345, "level": "warn", "status": "Busy", "samples": [1, 2, "x", 3], "rows": [{"title": "en0", "subtitle": "Wi-Fi", "value": "up", "id": "e0"}, "plain", {"no": "title"}, 42], "shapes": ["x", {"value": 2}, {"value": [1]}], "error": "Oops"}"#
        #expect(try await preview(["--state", state]) == (0, #"""
            Every control 3.1 (every)
            switch: on
            status: "Busy", level: "warn", error: "Oops"
            page:
              section "Inputs 2"
                toggle "Enabled thing": on (bind on = true; runs go; help "Turns it on")
                slider "Volume": 40% (bind volume = 40; 0…100 step 5; runs go; live)
                stepper "Count": 2 times (bind count = 2; from 1 step 1)
                stepper "Missing": -2 (bind absent missing, not a number: shows -2; up to -2 step 1)
                picker "Mode": "Bee" (bind mode = "b"; segmented)
                  option "a": "a"
                  option "b": "Bee" [selected]
                  option 3: "Three"
                picker: "x" (bind shape = "x"; menu; options from shapes)
                  1 element(s) of shapes skipped: not options, or beyond 32
                  option "x": "x" [selected]
                  option 2: "2"
                input "Host": "example.com" (bind host = "example.com"; placeholder "name"; runs go)
                footer: "Changed 2 times"
              section "More" (collapsible, starts collapsed)
                row
                  stat "Load": "2.3" (tint "warn")
                  stat "Hidden": "x" [hidden]
                row [hidden: nothing inside is shown]
                  text: "never" [hidden]
              divider
              button "Go example.com" (runs go; value 7; destructive; asks "Really?")
              button "Docs" (opens https://example.com/docs)
              button "Copy" (copies "example.com:2")
              value "Status": "Busy" (tint "purplish" (not a colour: ignored); copyable)
              text: "4 rows" (mono)
              gauge "Load": 2.35 (bind load = 2.345; 0…8 ring; tint "#FF8800")
              gauge "Empty": — (bind nothing missing, not a number: shows the minimum; 0…100 bar)
              chart "History" (bar, 30 points, 0…auto; unit " ms")
                series "Load": load = 2.345, recorded as one sample per patch that has it (tint "orange")
                series: samples = 3 numbers plotted as they are, other elements skipped
                series: status = "Busy", not a number or an array of numbers: nothing to plot
              list: 2 rows (bind rows; limit 2; runs go)
                row "en0", subtitle "Wi-Fi", value "up", id "e0"
                row "plain"
                1 element(s) skipped: neither text, a number nor an object with a title
              list: 0 rows (bind none missing)
                empty: "Nothing yet"
            widgets:
              widget load "Load 2.345": "2.3" (medium, 2 columns; tint "warn")
                chart (area, 20 points, auto…10)
                  series: samples = 3 numbers plotted as they are, other elements skipped
                detail:
                  value "Now": "2.345"
              widget gauge "Every control": "40%" (small, 1 column) [hidden]
                gauge: bind volume = 40, 0…200, 20% full
                no detail: a click opens the mod's page

            """#, ""))
    }

    @Test func outlinesTheStartingStateInALanguage() async throws {
        #expect(try await preview(["--language", "ru-RU"]) == (0, #"""
            Все элементы 3.1 (every), language ru-RU
            switch: off
            status: none, level: none, error: none
            page:
              section "Inputs 2"
                toggle "Enabled thing": on (bind on = true; runs go; help "Turns it on")
                slider "Громкость": 40% (bind volume = 40; 0…100 step 5; runs go; live)
                stepper "Count": 2 times (bind count = 2; from 1 step 1)
                stepper "Missing": -2 (bind absent missing, not a number: shows -2; up to -2 step 1)
                picker "Mode": "Пчела" (bind mode = "b"; segmented)
                  option "a": "a"
                  option "b": "Пчела" [selected]
                  option 3: "Three"
                picker: nothing selected (bind shape = "x"; menu; options from shapes)
                  no options: shapes holds no array yet
                input "Host": "example.com" (bind host = "example.com"; placeholder "name"; runs go) [disabled]
                footer: "Changed 2 times"
              section "More" (collapsible, starts collapsed)
                row
                  stat "Load": "—" (tint empty: the default colour)
                  stat "Hidden": "x" [hidden]
                row [hidden]
                  text: "never" [hidden]
              divider
              button "Go example.com" (runs go; value 7; destructive; asks "Really?")
              button "Docs" (opens https://example.com/docs)
              button "Copy" (copies "example.com:2")
              value "Status": "none" (tint "purplish" (not a colour: ignored); copyable)
              text: " rows" (mono)
              gauge "Load": — (bind load missing, not a number: shows the minimum; 0…8 ring; tint "#FF8800")
              gauge "Empty": — (bind nothing missing, not a number: shows the minimum; 0…100 bar)
              chart "History" (bar, 30 points, 0…auto; unit " ms")
                series "Load": load missing, nothing to plot yet (tint "orange")
                series: samples missing, nothing to plot yet
                series: status missing, nothing to plot yet
              list: 0 rows (bind rows missing; limit 2; runs go)
                empty: "Пока пусто"
              list: 0 rows (bind none missing)
                empty: "Пока пусто"
            widgets:
              widget load "Load ": "" (medium, 2 columns; tint empty: the default colour)
                chart (area, 20 points, auto…10)
                  series: samples missing, nothing to plot yet
                detail:
                  value "Now": ""
              widget gauge "Все элементы": "40%" (small, 1 column)
                gauge: bind volume = 40, 0…200, 20% full
                no detail: a click opens the mod's page

            """#, ""))
    }

    @Test func runsNothingAndShowsAModWithoutAPage() async throws {
        let directory = try TemporaryDirectory()
        let folder = try writeMod(manifest(#"""
            "summary": "Plain", "commands": {"touch": {"shell": "touch ran"}},
            "lifecycle": {"refresh": {"command": "touch"}, "events": {"launch": "touch"}}
            """#), in: directory)
        #expect(try await toolsyMod(["preview", folder.path(percentEncoded: false), "--state", #"{"status": 7, "level": "green"}"#]) == (0, """
            Demo 1.0 (demo)
            status: 7 (not text: not shown), level: "green" (not ok, warn, error or off: ignored), error: none
            page:
              no controls: Toolsy shows the status and the summary
            widgets: none

            """, ""))
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "ran").path(percentEncoded: false)))
        // A lone manifest and a package preview as well.
        try directory.write(manifest(id: "lone"), to: "lone.json")
        #expect(try await toolsyMod(["preview", "lone.json"], in: directory.url).output.hasPrefix("Demo 1.0 (lone)\n"))
    }

    @Test func refusesWhatItCannotShow() async throws {
        let unknownLanguage = try await preview(["--language", "de"])
        #expect(unknownLanguage.status == 2 && unknownLanguage.error.hasPrefix(#"toolsy-mod: --language: every has no localization for "de"; it has: ru"#))
        let badKey = try await preview(["--state", #"{"a b": 1}"#])
        #expect(badKey.status == 2 && badKey.error.hasPrefix(#"toolsy-mod: --state: "a b" is not a valid state key"#))
        let badJSON = try await preview(["--state", "{"])
        #expect(badJSON.status == 2 && badJSON.error.hasPrefix("toolsy-mod: --state: not JSON ("))

        let directory = try TemporaryDirectory()
        let broken = try writeMod(manifest(#""ui": [{"type": "text", "text": "{{x|shout}}"}]"#), in: directory)
        #expect(try await toolsyMod(["preview", broken.path(percentEncoded: false)]) == (1, "", "ui[0].text: unknown filter \"shout\"\n"))
    }
}
