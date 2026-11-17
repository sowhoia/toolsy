import Foundation
import Testing
@testable import ToolsyShared

private func manifest(_ json: String) throws -> ModManifest {
    try ModManifest.load(from: Data(json.utf8))
}

/// A minimal valid manifest with `extra` spliced into the top-level object.
private func minimal(_ extra: String = "") -> String {
    #"{"schema": 1, "id": "demo", "name": "Demo", "version": "1.0""# + (extra.isEmpty ? "" : ", " + extra) + "}"
}

private func failure(_ json: String) -> String {
    do {
        _ = try manifest(json)
        return "no error"
    } catch {
        return error.localizedDescription
    }
}

@Suite struct JSONValueTests {
    @Test func decodesEveryKind() throws {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"a": null, "b": true, "c": 1, "d": 2.5, "e": "x", "f": [1, "y"]}"#.utf8))
        #expect(value == ["a": nil, "b": true, "c": 1, "d": 2.5, "e": "x", "f": [1, "y"]])
    }

    @Test func roundTrips() throws {
        let value: JSONValue = ["on": false, "n": 3, "list": ["a", ["k": 1.5]]]
        let decoded = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
        #expect(decoded == value)
    }

    @Test func textDropsTrailingZeroOfWholeNumbers() {
        #expect(JSONValue.number(42).text == "42")
        #expect(JSONValue.number(-3).text == "-3")
        #expect(JSONValue.number(0.25).text == "0.25")
        #expect(JSONValue.bool(true).text == "true")
        #expect(JSONValue.null.text == "")
        #expect(JSONValue.array([1, "a"]).text == #"[1,"a"]"#)
    }

    @Test func truthiness() {
        #expect(!JSONValue.null.isTruthy)
        #expect(!JSONValue.bool(false).isTruthy)
        #expect(!JSONValue.number(0).isTruthy)
        #expect(!JSONValue.string("").isTruthy)
        #expect(!JSONValue.array([]).isTruthy)
        #expect(JSONValue.string("false").isTruthy)
        #expect(JSONValue.number(-1).isTruthy)
    }
}

@Suite struct RequiredToolsyVersionTests {
    @Test func acceptsThisVersionAndOlderOnes() throws {
        for version in ["1", "1.0", "1.1", ToolsyVersion.current] {
            #expect(try manifest(minimal(#""toolsy": "\#(version)""#)).toolsy == version)
        }
        #expect(try manifest(minimal()).toolsy == nil)
    }

    /// Without the field a mod written for a later Toolsy failed with "unknown control type", or worse, had a
    /// new field silently ignored.
    @Test func refusesAModForALaterToolsy() {
        for version in ["1.10", "2", "1.1.1"] {
            #expect(failure(minimal(#""toolsy": "\#(version)""#)) == "needs Toolsy \(version) or later; this is Toolsy \(ToolsyVersion.current)")
        }
    }

    @Test func refusesWhatIsNotAVersion() {
        for version in ["", "v1.1", "1.1.0.1", "1.x", "1..2"] {
            #expect(failure(minimal(#""toolsy": "\#(version)""#)) == #"toolsy must be a version such as "1.1" or "1.1.0""#, "\(version)")
        }
    }
}

@Suite struct ManifestDecodingTests {
    @Test func appliesDefaults() throws {
        let mod = try manifest(minimal())
        #expect(mod.settings.isEmpty)
        #expect(mod.commands.isEmpty)
        #expect(mod.ui.isEmpty)
        #expect(!mod.lifecycle.hasToggle)
        #expect(!mod.requiresPrivileges)
    }

    @Test func decodesCommandsAndLifecycle() throws {
        let mod = try manifest(minimal(#"""
        "settings": {"host": "1.1.1.1", "interval": 5},
        "commands": {
            "on": {"exec": "bin/tool", "args": ["enable"], "privileged": true, "stdin": true, "timeout": 60},
            "status": {"shell": "echo ok", "capture": "status"},
            "watch": {"exec": "bin/watch"}
        },
        "lifecycle": {"enable": "on", "service": "watch", "refresh": {"command": "status", "every": 10}}
        """#))
        #expect(mod.commands["on"]?.program == .exec("bin/tool"))
        #expect(mod.commands["on"]?.args == ["enable"])
        #expect(mod.commands["on"]?.privileged == true)
        #expect(mod.commands["on"]?.stdin == true)
        #expect(mod.commands["on"]?.timeout == 60)
        #expect(mod.commands["status"]?.program == .shell("echo ok"))
        #expect(mod.commands["status"]?.timeout == ModCommand.defaultTimeout)
        #expect(mod.commands["status"]?.capture == "status")
        #expect(mod.lifecycle.hasToggle)
        #expect(mod.lifecycle.refresh?.every == 10)
        #expect(mod.lifecycle.refresh?.background == false)
        #expect(mod.requiresPrivileges)
        #expect(mod.settings["interval"] == 5)
    }

    @Test func decodesEveryControl() throws {
        let mod = try manifest(minimal(#"""
        "commands": {"go": {"shell": "true"}},
        "ui": [
            {"type": "section", "title": "Main", "footer": "{{status}}", "when": "enabled", "children": [
                {"type": "toggle", "label": "Auto", "bind": "auto", "command": "go"},
                {"type": "slider", "label": "Level", "bind": "level_pct", "min": 0, "max": 100, "step": 5, "unit": "%", "live": true},
                {"type": "stepper", "label": "Count", "bind": "count", "min": 1, "max": 9},
                {"type": "picker", "label": "Mode", "bind": "mode", "options": ["fast", {"value": 2, "label": "Two", "icon": "2.circle"}]},
                {"type": "input", "label": "Host", "bind": "host", "placeholder": "example.com", "disabled": "enabled"},
                {"type": "divider"},
                {"type": "row", "children": [
                    {"type": "button", "label": "Run", "command": "go", "value": "x", "style": "prominent", "confirm": "Sure?"},
                    {"type": "button", "label": "Docs", "open": "https://example.com"}
                ]}
            ]},
            {"type": "value", "label": "IP", "value": "{{ip}}", "copyable": true, "tint": "{{level}}"},
            {"type": "text", "text": "Hello", "style": "caption"},
            {"type": "gauge", "label": "Load", "bind": "load", "style": "ring"},
            {"type": "chart", "label": "Ping", "series": [{"bind": "ping", "label": "ms", "tint": "blue"}], "style": "area", "points": 30},
            {"type": "list", "bind": "rows", "command": "go", "empty": "Nothing", "limit": 5}
        ]
        """#))
        #expect(mod.ui.count == 6)
        guard case .section(let section) = mod.ui[0].kind else {
            Issue.record("expected a section")
            return
        }
        #expect(mod.ui[0].when == "enabled")
        #expect(section.children.count == 7)
        guard case .slider(let slider) = section.children[1].kind,
              case .stepper(let stepper) = section.children[2].kind,
              case .picker(let picker) = section.children[3].kind,
              case .row(let row) = section.children[6].kind,
              case .button(let run) = row.children[0].kind,
              case .button(let docs) = row.children[1].kind,
              case .value(let value) = mod.ui[1].kind,
              case .text(let text) = mod.ui[2].kind,
              case .gauge(let gauge) = mod.ui[3].kind,
              case .chart(let chart) = mod.ui[4].kind
        else {
            Issue.record("controls decoded into unexpected kinds")
            return
        }
        #expect(slider.live && slider.step == 5 && slider.unit == "%")
        #expect(stepper.step == 1)
        #expect(picker.options.map(\.label) == ["fast", "Two"])
        #expect(picker.options.map(\.value) == ["fast", 2])
        #expect(picker.style == nil)
        #expect(section.children[4].disabled == "enabled")
        #expect(run.style == .prominent && run.value == "x" && run.confirm == "Sure?")
        #expect(docs.style == .normal && docs.open == "https://example.com")
        #expect(value.copyable)
        #expect(text.style == .caption)
        #expect(gauge.min == 0 && gauge.max == 100 && gauge.style == .ring)
        #expect(chart.points == 30 && chart.style == .area && chart.series[0].bind == "ping")
    }

    @Test func reportsWhereDecodingFailed() {
        #expect(failure(#"{"schema": 1, "id": "demo", "name": "Demo"}"#) == #"missing required field "version""#)
        #expect(failure(minimal(#""ui": [{"type": "section", "children": [{"type": "knob"}]}]"#))
            == #"ui[0].children[0].type: unknown control type "knob""#)
        #expect(failure(minimal(#""commands": {"x": {"exec": "a", "shell": "b"}}"#))
            == #"commands.x: a command needs exactly one of "exec" and "shell""#)
        #expect(failure(minimal(#""ui": [{"type": "slider", "label": "L", "bind": "v", "min": 0}]"#))
            == #"ui[0]: missing required field "max""#)
        #expect(failure("not json").contains("not valid JSON"))
    }
}

@Suite struct ManifestValidationTests {
    @Test func rejectsBadIdentity() {
        #expect(failure(#"{"schema": 2, "id": "demo", "name": "Demo", "version": "1"}"#).contains("schema 2"))
        for id in ["", "Demo", "../x", "a/b", "-a", "a.", String(repeating: "a", count: 65)] {
            #expect(failure(#"{"schema": 1, "id": "\#(id)", "name": "Demo", "version": "1"}"#).contains("is invalid"), "id \(id)")
        }
        #expect(failure(#"{"schema": 1, "id": "demo", "name": " ", "version": "1"}"#).contains("name"))
    }

    @Test func acceptsReverseDNSIdentifiers() throws {
        _ = try manifest(#"{"schema": 1, "id": "com.example.my-mod_2", "name": "Demo", "version": "1"}"#)
    }

    @Test func rejectsReservedSettings() {
        #expect(failure(minimal(#""settings": {"enabled": true}"#)).contains("reserved"))
        #expect(failure(minimal(#""settings": {"bad-key": 1}"#)).contains("not a valid key"))
    }

    @Test func rejectsUnsafeCommands() {
        #expect(failure(minimal(#""commands": {"x": {"exec": "../evil"}}"#)).contains("relative path inside the mod"))
        #expect(failure(minimal(#""commands": {"x": {"exec": "/bin/sh"}}"#)).contains("relative path inside the mod"))
        #expect(failure(minimal(#""commands": {"x": {"shell": "  "}}"#)).contains("must not be empty"))
        #expect(failure(minimal(#""commands": {"x": {"shell": "true", "timeout": 0}}"#)).contains("timeout"))
        #expect(failure(minimal(#""commands": {"x": {"shell": "true", "capture": "enabled"}}"#)).contains("capture"))
        #expect(failure(minimal(#""commands": {"bad name": {"shell": "true"}}"#)).contains("command names"))
    }

    @Test func rejectsBrokenLifecycle() {
        #expect(failure(minimal(#""lifecycle": {"enable": "missing"}"#)) == #"lifecycle.enable: command "missing" is not defined"#)
        #expect(failure(minimal(#""commands": {"d": {"shell": "true", "privileged": true}}, "lifecycle": {"service": "d"}"#))
            .contains("cannot be privileged"))
        #expect(failure(minimal(#""commands": {"d": {"shell": "true", "capture": "x"}}, "lifecycle": {"service": "d"}"#))
            .contains("cannot use capture"))
        #expect(failure(minimal(#""commands": {"d": {"shell": "true"}}, "lifecycle": {"service": "d", "refresh": {"command": "d"}}"#))
            .contains("cannot also be the refresh command"))
        #expect(failure(minimal(#""commands": {"s": {"shell": "true"}}, "lifecycle": {"refresh": {"command": "s", "every": 0.2}}"#))
            .contains("at least 1 second"))
    }

    @Test func rejectsBrokenControls() {
        func ui(_ controls: String) -> String {
            failure(minimal(#""commands": {"go": {"shell": "true"}}, "ui": [\#(controls)]"#))
        }
        #expect(ui(#"{"type": "toggle", "label": "T", "bind": "t", "command": "nope"}"#) == #"ui[0]: command "nope" is not defined"#)
        #expect(ui(#"{"type": "toggle", "label": "T", "bind": "not valid"}"#).contains("not a valid key"))
        #expect(ui(#"{"type": "toggle", "label": "T", "bind": "enabled"}"#).contains("managed by the host"))
        #expect(ui(#"{"type": "gauge", "label": "G", "bind": "level"}"#) == "no error")
        #expect(ui(#"{"type": "slider", "label": "S", "bind": "s", "min": 5, "max": 5}"#).contains("min must be less than max"))
        #expect(ui(#"{"type": "slider", "label": "S", "bind": "s", "min": 0, "max": 5, "step": 0}"#).contains("step must be positive"))
        #expect(ui(#"{"type": "picker", "bind": "p", "options": []}"#).contains("1–32 options"))
        #expect(ui(#"{"type": "picker", "bind": "p", "options": [{"value": [1], "label": "x"}]}"#).contains("option values"))
        #expect(ui(#"{"type": "button", "label": "B"}"#).contains("exactly one"))
        #expect(ui(#"{"type": "button", "label": "B", "command": "go", "open": "https://example.com"}"#).contains("exactly one"))
        #expect(ui(#"{"type": "button", "label": "B", "open": "file:///etc/passwd"}"#).contains("http or https"))
        #expect(ui(#"{"type": "chart", "series": []}"#).contains("1–6 series"))
        #expect(ui(#"{"type": "chart", "series": [{"bind": "x"}], "points": 1}"#).contains("points"))
        #expect(ui(#"{"type": "row", "children": [{"type": "section", "children": []}]}"#).contains("cannot contain"))
        #expect(ui(#"{"type": "row", "children": []}"#).contains("1–4 controls"))
    }

    @Test func limitsNesting() {
        func nested(_ levels: Int) -> String {
            var control = #"{"type": "divider"}"#
            for _ in 0..<levels {
                control = #"{"type": "section", "children": [\#(control)]}"#
            }
            return failure(minimal(#""ui": [\#(control)]"#))
        }
        #expect(nested(3) == "no error")
        #expect(nested(4).contains("nested deeper"))
    }
}

@Suite struct ListItemTests {
    @Test func readsObjectsAndScalars() {
        let items = ModListItem.items(from: [
            "plain",
            7,
            ["title": "Row", "subtitle": "sub", "value": 12, "icon": "wifi", "tint": "green", "id": "r1"],
            ["subtitle": "no title"],
            ["nested"],
        ])
        #expect(items.map(\.title) == ["plain", "7", "Row"])
        #expect(items.map(\.id) == ["plain", "7", "r1"])
        #expect(items[2].value == "12" && items[2].subtitle == "sub" && items[2].icon == "wifi")
    }

    @Test func toleratesMissingOrWrongValues() {
        #expect(ModListItem.items(from: nil).isEmpty)
        #expect(ModListItem.items(from: "text").isEmpty)
    }
}
