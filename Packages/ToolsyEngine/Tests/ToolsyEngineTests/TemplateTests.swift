import Foundation
import Testing
@testable import ToolsyEngine
import ToolsyShared

private func render(_ template: String, _ state: ModState = [:]) throws -> String {
    try ModTemplate(template).render(state)
}

private func syntaxError(_ template: String) -> String? {
    do {
        _ = try ModTemplate(template)
        return nil
    } catch {
        return error.message
    }
}

@Suite struct TemplateTests {
    @Test func substitutesValues() throws {
        let state: ModState = ["s": "text", "whole": 42, "half": 2.5, "on": true, "list": [1, "a"], "nothing": nil]
        #expect(try render("{{s}} {{whole}} {{half}} {{on}} {{list}}", state) == #"text 42 2.5 true [1,"a"]"#)
        #expect(try render("[{{missing}}][{{nothing}}]", state) == "[][]")
        #expect(try render("no placeholders, {single} braces") == "no placeholders, {single} braces")
        #expect(try render("{{ s | default:x }}", state) == "text")
    }

    @Test func formatsBytesAndRates() throws {
        let cases: [(Double, String)] = [
            (0, "0 B"), (512, "512 B"), (1_500, "1.5 KB"), (2_000_000, "2 MB"), (999_960, "1 MB"),
            (1_500_000_000, "1.5 GB"), (123_400_000, "123.4 MB"), (-2_500, "-2.5 KB"),
        ]
        for (bytes, text) in cases {
            #expect(try render("{{b|bytes}}", ["b": .number(bytes)]) == text, "\(bytes)")
        }
        #expect(try render("{{r|rate}}", ["r": 1_200_000]) == "1.2 MB/s")
    }

    @Test func formatsPercentRoundAndFixed() throws {
        #expect(try render("{{p|percent}}", ["p": 42.4]) == "42%")
        #expect(try render("{{p|percent}}", ["p": 99.6]) == "100%")
        #expect(try render("{{n|round}}", ["n": 2.5]) == "3")
        #expect(try render("{{n|round}}", ["n": -2.5]) == "-3")
        #expect(try render("{{n|fixed:2}}", ["n": 3.14159]) == "3.14")
        #expect(try render("{{n|fixed:2}}", ["n": 2]) == "2.00")
        #expect(try render("{{n|fixed:0}}", ["n": 2.7]) == "3")
    }

    @Test func formatsDurations() throws {
        let cases: [(Double, String)] = [
            (0, "0s"), (45, "45s"), (59.9, "59s"), (200, "3m 20s"), (65, "1m 05s"),
            (7_500, "2h 05m"), (100_800, "1d 4h"), (90_061, "1d 1h"), (-45, "-45s"),
        ]
        for (seconds, text) in cases {
            #expect(try render("{{t|duration}}", ["t": .number(seconds)]) == text, "\(seconds)")
        }
    }

    @Test func numericFiltersLeaveNonNumbersAlone() throws {
        for filter in ["bytes", "rate", "percent", "duration", "round", "fixed:1"] {
            #expect(try render("{{v|\(filter)}}", ["v": "n/a"]) == "n/a", "\(filter)")
            #expect(try render("{{v|\(filter)}}", ["v": "12"]) == "12", "a numeric string is still a string for \(filter)")
            #expect(try render("[{{v|\(filter)}}]") == "[]", "missing key with \(filter)")
            #expect(try render("{{v|\(filter)}}", ["v": true]) == "true")
        }
    }

    @Test func defaultReplacesMissingAndEmptyValues() throws {
        #expect(try render("{{v|default:none}}") == "none")
        #expect(try render("{{v|default:none}}", ["v": ""]) == "none")
        #expect(try render("{{v|default:none}}", ["v": nil]) == "none")
        #expect(try render("{{v|default:none}}", ["v": 0]) == "0")
        #expect(try render("{{v|default:none}}", ["v": false]) == "false")
        #expect(try render("[{{v|default: n/a }}]") == "[ n/a ]", "the text is kept as written")
        #expect(try render("[{{v|default:}}]") == "[]")
    }

    @Test func chainsFiltersLeftToRight() throws {
        #expect(try render("{{ping|fixed:1|default:—}} ms") == "— ms")
        #expect(try render("{{ping|fixed:1|default:—}} ms", ["ping": 23.46]) == "23.5 ms")
        #expect(try render("{{x|round|percent}}", ["x": 41.6]) == "42%")
        #expect(try render("{{x|percent|round}}", ["x": 41.6]) == "42%", "round after a string result does nothing")
        #expect(try render("{{x|default:5|fixed:1}}") == "5", "default produces text, which fixed leaves alone")
        #expect(try render("{{a}}/{{b|bytes}}", ["a": 1, "b": 2_048]) == "1/2 KB")
    }

    @Test func rejectsMalformedTemplates() {
        #expect(syntaxError("{{a") == #""{{" is not closed"#)
        #expect(syntaxError("a {{b {{c}}") == #""{{" is not closed"#)
        #expect(syntaxError("a}}") == #""}}" has no matching "{{""#)
        #expect(syntaxError("{{a}} b}}") == #""}}" has no matching "{{""#)
        #expect(syntaxError("{{}}")?.contains("valid state key") == true)
        #expect(syntaxError("{{bad key}}")?.contains("valid state key") == true)
        #expect(syntaxError("{{1abc}}")?.contains("valid state key") == true)
        #expect(syntaxError("{{a|shout}}") == #"unknown filter "shout""#)
        #expect(syntaxError("{{a|}}") == #"unknown filter """#)
        #expect(syntaxError("{{a|fixed}}")?.contains("fixed needs") == true)
        #expect(syntaxError("{{a|fixed:x}}")?.contains("fixed needs") == true)
        #expect(syntaxError("{{a|fixed:11}}")?.contains("fixed needs") == true)
        #expect(syntaxError("{{a|default}}")?.contains("default needs") == true)
        #expect(syntaxError("{{a|round:2}}") == #"the filter "round" takes no argument"#)
        #expect(syntaxError("plain") == nil)
        #expect(syntaxError("{{a|bytes|default:—}}") == nil)
    }
}
