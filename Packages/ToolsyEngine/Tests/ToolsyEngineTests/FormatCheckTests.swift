import Foundation
import Testing
@testable import ToolsyEngine
import ToolsyShared

/// What `toolsy-mod validate` and installing report for a manifest, short of checking its program files.
private func check(_ json: String) -> String {
    do {
        try ModManifest.load(from: Data(json.utf8)).validateTemplatesAndExpressions()
        return "no error"
    } catch {
        return error.localizedDescription
    }
}

private func minimal(_ extra: String) -> String {
    #"{"schema": 1, "id": "demo", "name": "Demo", "version": "1.0", "commands": {"go": {"shell": "true"}}, \#(extra)}"#
}

@Suite struct FormatCheckTests {
    @Test func checksWidgetTemplatesAndExpressions() {
        #expect(check(minimal(#""widgets": [{"id": "a", "value": "{{x|shout}}"}]"#)) == #"widgets[0].value: unknown filter "shout""#)
        #expect(check(minimal(#""widgets": [{"id": "a", "value": "x"}, {"id": "b", "title": "{{t", "value": "x"}]"#))
            == #"widgets[1].title: "{{" is not closed"#)
        #expect(check(minimal(#""widgets": [{"id": "a", "value": "x", "tint": "{{level|fixed}}"}]"#))
            == "widgets[0].tint: fixed needs a number of decimals from 0 to 10, as in fixed:1")
        #expect(check(minimal(#""widgets": [{"id": "a", "value": "x", "when": "a =="}]"#))
            == "widgets[0].when: the expression ends where a value is expected")
        #expect(check(minimal(#""widgets": [{"id": "a", "value": "x", "detail": [{"type": "divider"}, {"type": "divider"}, {"type": "text", "text": "y", "when": "(a"}]}]"#))
            == #"widgets[0].detail[2].when: "(" is not closed"#)
        #expect(check(minimal(#""widgets": [{"id": "a", "value": "x", "detail": [{"type": "row", "children": [{"type": "stat", "label": "L", "value": "{{v|"}]}]}]"#))
            == #"widgets[0].detail[0].children[0].value: "{{" is not closed"#)
        #expect(check(minimal(#""widgets": [{"id": "a", "title": "{{name|upper}}", "value": "{{used/total}}"}]"#)).contains("valid state key or path"))
    }

    @Test func checksNewControlFields() {
        #expect(check(minimal(#""ui": [{"type": "stat", "label": "{{a|nope}}", "value": "x"}]"#)) == #"ui[0].label: unknown filter "nope""#)
        #expect(check(minimal(#""ui": [{"type": "stat", "label": "L", "value": "x", "tint": "{{"}]"#)) == #"ui[0].tint: "{{" is not closed"#)
        #expect(check(minimal(#""ui": [{"type": "button", "label": "B", "copy": "{{ip|truncate:0}}"}]"#))
            == "ui[0].copy: truncate needs a length from 1 to 500, as in truncate:20")
        #expect(check(minimal(#""ui": [{"type": "gauge", "label": "G", "bind": "g", "format": "kilo"}]"#)) == #"ui[0].format: unknown filter "kilo""#)
        #expect(check(minimal(#""ui": [{"type": "chart", "series": [{"bind": "c"}], "format": "div:0"}]"#))
            == "ui[0].format: div needs a number other than 0, as in div:1000")
        #expect(check(minimal(#""ui": [{"type": "section", "children": [{"type": "chart", "series": [{"bind": "c"}], "format": "bytes|"}]}]"#))
            == #"ui[0].children[0].format: unknown filter """#)
        #expect(check(minimal(#""ui": [{"type": "button", "label": "B", "copy": "{{", "help": "{{ not a template"}]"#))
            == #"ui[0].copy: "{{" is not closed"#, "help is plain text and never parsed")
        #expect(check(minimal(#"""
            "ui": [
                {"type": "gauge", "label": "G", "bind": "g", "format": "div:1000|fixed:1"},
                {"type": "chart", "series": [{"bind": "c"}], "format": "bitrate"},
                {"type": "section", "title": "{{disk.name|upper}}", "collapsible": true, "children": [
                    {"type": "button", "label": "B", "copy": "{{ip}}", "help": "{{ip"}
                ]}
            ]
            """#)) == "no error")
    }

    @Test func checksEveryTranslation() {
        let base = #""ui": [{"type": "value", "label": "Latency", "value": "{{ms}} ms"}], "widgets": [{"id": "a", "value": "{{ms}} ms"}]"#
        #expect(check(minimal(base + #", "localizations": {"ru": {"{{ms}} ms": "{{ms}} мс"}, "de": {"Latency": "Latenz"}}"#)) == "no error")
        #expect(check(minimal(base + #", "localizations": {"ru": {"{{ms}} ms": "{{ms мс"}}"#))
            == #"localizations.ru: ui[0].value: "{{" is not closed"#)
        #expect(check(minimal(base + #", "localizations": {"de": {}, "ru": {"Latency": "{{x|loud}}"}}"#))
            == #"localizations.ru: ui[0].label: unknown filter "loud""#)
        #expect(check(minimal(#""widgets": [{"id": "a", "value": "Now"}], "localizations": {"ru": {"Now": "{{now"}}"#))
            == #"localizations.ru: widgets[0].value: "{{" is not closed"#)
        #expect(check(minimal(#""ui": [{"type": "text", "text": "Hi"}], "localizations": {"ru": {"Unused": "{{"}}"#)) == "no error",
                "an entry nothing uses is never rendered")
    }
}
