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

/// A fixed locale, time zone and clock, so the locale-dependent filters render the same everywhere.
private func context(_ locale: String, now: Date = Date(timeIntervalSince1970: 1_763_300_000)) -> FormatContext {
    FormatContext(locale: Locale(identifier: locale), timeZone: TimeZone(identifier: "UTC")!, now: now)
}

private func render(_ template: String, _ state: ModState = [:], in context: FormatContext) throws -> String {
    try ModTemplate(template).render(state, in: context)
}

@Suite struct TemplatePathTests {
    private let state: ModState = [
        "disk": ["free": 1_500_000_000, "name": "Macintosh HD", "0": "zero key"],
        "rows": [["title": "en0", "tags": ["wifi"]], ["title": "utun4"]],
        "text": "plain",
    ]

    @Test func walksObjectsAndArrays() throws {
        #expect(try render("{{disk.free|bytes}} on {{disk.name}}", state) == "1.5 GB on Macintosh HD")
        #expect(try render("{{rows.0.title}}, {{rows.1.title}}, {{rows.0.tags.0}}", state) == "en0, utun4, wifi")
        #expect(try render("{{disk.0}}", state) == "zero key", "a number indexes an object by key")
        #expect(try render("{{rows.1}}", state) == #"{"title":"utun4"}"#)
    }

    @Test func aMissingStepRendersNothing() throws {
        for path in ["disk.size", "rows.2.title", "rows.first", "rows.0.title.x", "text.length", "disk.free.x", "nope.x"] {
            #expect(try render("[{{\(path)}}]", state) == "[]", "\(path)")
            #expect(try render("{{\(path)|default:—}}", state) == "—", "\(path)")
        }
    }

    @Test func rejectsMalformedPaths() {
        for path in ["a.", ".a", "a..b", "a.-1", "a.b-c", "a. b", "1a.b", "a.\(String(repeating: "x", count: 65))"] {
            #expect(syntaxError("{{\(path)}}") == #""{{\#(path)}}" does not start with a valid state key or path"#, "\(path)")
        }
        #expect(syntaxError("{{ rows.0.title | default:x }}") == nil)
        #expect(syntaxError("{{a.\(String(repeating: "x", count: 64))}}") == nil)
    }
}

@Suite struct TemplateFilterTests {
    @Test func changesCase() throws {
        #expect(try render("{{s|upper}} {{s|lower}}", ["s": "Wi-Fi ä"]) == "WI-FI Ä wi-fi ä")
        #expect(try render("{{n|upper}} {{b|lower}}", ["n": 5, "b": true]) == "5 true", "non-strings are left alone")
    }

    @Test func truncates() throws {
        #expect(try render("{{s|truncate:5}}", ["s": "abcdefgh"]) == "abcd…")
        #expect(try render("{{s|truncate:8}}", ["s": "abcdefgh"]) == "abcdefgh", "a text that fits is kept")
        #expect(try render("{{s|truncate:1}}", ["s": "ab"]) == "…")
        #expect(try render("{{s|truncate:7}}", ["s": "hello world"]) == "hello…", "no space before the ellipsis")
        #expect(try render("{{s|truncate:3}}", ["s": "🇷🇺🇩🇪🇫🇷🇮🇹"]) == "🇷🇺🇩🇪…", "characters, not bytes")
        #expect(try render("{{n|truncate:2}}", ["n": 12345]) == "12345")
        #expect(try render("{{n|bytes|truncate:4}}", ["n": 1_500_000]) == "1.5…")
    }

    @Test func groupsNumbersForTheLocale() throws {
        #expect(try render("{{n|number}}", ["n": 1_234_567.891], in: context("en_US")) == "1,234,567.89")
        #expect(try render("{{n|number}}", ["n": 1_234_567.891], in: context("ru_RU")) == "1\u{A0}234\u{A0}567,89")
        #expect(try render("{{n|number}}", ["n": 0.5], in: context("de_DE")) == "0,5")
        #expect(try render("{{n|number}}", ["n": 42], in: context("en_US")) == "42")
        #expect(try render("{{n|number}}", ["n": "1234"], in: context("en_US")) == "1234")
    }

    @Test func formatsBitrates() throws {
        let cases: [(Double, String)] = [
            (0, "0 bit/s"), (100, "800 bit/s"), (1_550_000, "12.4 Mbit/s"), (125_000, "1 Mbit/s"),
            (125_000_000, "1 Gbit/s"), (250_000_000_000, "2000 Gbit/s"), (124_993, "999.9 kbit/s"),
        ]
        for (rate, text) in cases {
            #expect(try render("{{r|bitrate}}", ["r": .number(rate)]) == text, "\(rate)")
        }
    }

    @Test func formatsTimesAndDates() throws {
        let at: ModState = ["t": 1_763_300_000]  // 2025-11-16 13:33:20 UTC
        #expect(try render("{{t|time}}", at, in: context("ru_RU")) == "13:33")
        #expect(try render("{{t|time}}", at, in: context("en_US")) == "1:33\u{202F}PM")
        #expect(try render("{{t|date}}", at, in: context("ru_RU")) == "16.11.2025")
        #expect(try render("{{t|date}}", at, in: context("en_US")) == "11/16/2025")
        var tokyo = context("ru_RU")
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        #expect(try render("{{t|time}} {{t|date}}", at, in: tokyo) == "22:33 16.11.2025")
    }

    @Test func formatsRelativeTimes() throws {
        let now = Date(timeIntervalSince1970: 1_763_300_000)
        func ago(_ seconds: Double, _ locale: String) throws -> String {
            try render("{{t|ago}}", ["t": .number(now.timeIntervalSince1970 - seconds)], in: context(locale, now: now))
        }
        #expect(try ago(300, "en_US") == "5 min. ago")
        #expect(try ago(300, "ru_RU") == "5 мин. назад")
        #expect(try ago(3 * 86_400, "en_US") == "3 days ago")
        #expect(try ago(0, "en_US") == "now")
        #expect(try ago(-60, "en_US") == "in 1 min.")
    }

    @Test func countsElementsAndCharacters() throws {
        #expect(try render("{{a|count}} {{o|count}} {{s|count}} {{e|count}}", ["a": [1, 2, 3], "o": ["x": 1], "s": "héllo", "e": ""]) == "3 1 5 0")
        #expect(try render("[{{n|count}}][{{m|count}}]", ["n": 12]) == "[12][]")
        #expect(try render("{{a|count|default:none}}", ["a": []]) == "0")
    }

    @Test func joinsArrays() throws {
        let state: ModState = ["a": ["en0", 2, true, nil, ["x"], ["k": 1]], "s": "text"]
        #expect(try render("{{a|join}}", state) == "en0, 2, true", "only scalars are joined")
        #expect(try render("{{a|join: / }}", state) == "en0 / 2 / true")
        #expect(try render("{{a|join:}}", state) == "en02true")
        #expect(try render("{{s|join}}", state) == "text")
        #expect(try render("[{{e|join}}]", ["e": []]) == "[]")
        #expect(try render("{{e|join|default:none}}", ["e": []]) == "none")
    }

    @Test func calculates() throws {
        #expect(try render("{{n|mul:8}}", ["n": 3]) == "24")
        #expect(try render("{{n|div:1000|fixed:1}}", ["n": 1234]) == "1.2")
        #expect(try render("{{n|add:-273.5|fixed:1}}", ["n": 300]) == "26.5")
        #expect(try render("{{n|mul:0.5|round}}", ["n": 5]) == "3")
        #expect(try render("{{n|div:1024|bytes}}", ["n": 2_048_000]) == "2 KB")
        #expect(try render("{{s|mul:2}}", ["s": "x"]) == "x")
        #expect(try render("[{{n|mul:10}}]", ["n": 1e308]) == "[]", "an overflow renders nothing")
    }

    @Test func choosesByTruthiness() throws {
        #expect(try render("{{v|either:on:off}}", ["v": true]) == "on")
        for value: JSONValue in [false, 0, "", nil, []] {
            #expect(try render("{{v|either:on:off}}", ["v": value]) == "off", "\(value)")
        }
        #expect(try render("{{v|either:on:off}}") == "off", "a missing key is falsy")
        #expect(try render("[{{v|either:Active:}}]", ["v": 0]) == "[]")
        #expect(try render("{{v|either:at:12:30}}", ["v": 1]) == "at")
        #expect(try render("{{v|either:at:12:30}}", ["v": 0]) == "12:30", "the second text runs to the end")
        #expect(try render("{{v|either: yes : no }}", ["v": 1]) == " yes ")
    }

    @Test func newNumericFiltersLeaveNonNumbersAlone() throws {
        for filter in ["bitrate", "number", "time", "date", "ago", "mul:2", "div:2", "add:1"] {
            #expect(try render("{{v|\(filter)}}", ["v": "n/a"]) == "n/a", "\(filter)")
            #expect(try render("{{v|\(filter)}}", ["v": "12"]) == "12", "\(filter)")
            #expect(try render("[{{v|\(filter)}}]") == "[]", "\(filter)")
            #expect(try render("{{v|\(filter)}}", ["v": true]) == "true", "\(filter)")
        }
    }

    @Test func rejectsBadArguments() {
        for bad in ["truncate", "truncate:0", "truncate:501", "truncate:x", "truncate:2.5"] {
            #expect(syntaxError("{{a|\(bad)}}") == "truncate needs a length from 1 to 500, as in truncate:20", "\(bad)")
        }
        #expect(syntaxError("{{a|truncate:500}}") == nil)
        for bad in ["mul", "mul:", "mul:x", "mul:1e3", "mul:0x10", "mul:inf", "mul:1.", "mul:.5"] {
            #expect(syntaxError("{{a|\(bad)}}") == "mul needs a number, as in mul:8", "\(bad)")
        }
        #expect(syntaxError("{{a|add}}") == "add needs a number, as in add:8")
        for bad in ["div", "div:0", "div:0.0", "div:-0", "div:k"] {
            #expect(syntaxError("{{a|\(bad)}}") == "div needs a number other than 0, as in div:1000", "\(bad)")
        }
        #expect(syntaxError("{{a|mul: -2.5 |add:0|div:0.001}}") == nil)
        for bad in ["either", "either:on", "either:"] {
            #expect(syntaxError("{{a|\(bad)}}") == #"either needs two texts separated by ":", as in either:on:off"#, "\(bad)")
        }
        for plain in ["upper", "lower", "number", "bitrate", "time", "date", "ago", "count"] {
            #expect(syntaxError("{{a|\(plain):1}}") == #"the filter "\#(plain)" takes no argument"#, "\(plain)")
            #expect(syntaxError("{{a|\(plain)}}") == nil, "\(plain)")
        }
        #expect(syntaxError("{{a|join}}") == nil)
        #expect(syntaxError("{{a|Upper}}") == #"unknown filter "Upper""#)
    }
}

@Suite struct ValueFormatTests {
    @Test func formatsNumbersWithAChain() throws {
        #expect(try ModValueFormat("bytes").string(for: 1_500_000) == "1.5 MB")
        #expect(try ModValueFormat("div:1000|fixed:1").string(for: 1234) == "1.2")
        #expect(try ModValueFormat("rate").string(for: 2_000) == "2 KB/s")
        #expect(try ModValueFormat("fixed:0|default:—").string(for: 2.4) == "2")
        #expect(try ModValueFormat("number").string(for: 1234.5, in: context("ru_RU")) == "1\u{A0}234,5")
        #expect(try ModValueFormat("div:0.5|either:big:small").string(for: 0) == "small")
    }

    @Test func rejectsWhatATemplateRejects() {
        func error(_ chain: String) -> String? {
            do {
                _ = try ModValueFormat(chain)
                return nil
            } catch {
                return error.message
            }
        }
        #expect(error("") == #"unknown filter """#)
        #expect(error("bytes|") == #"unknown filter """#)
        #expect(error("shout") == #"unknown filter "shout""#)
        #expect(error("fixed:x") == "fixed needs a number of decimals from 0 to 10, as in fixed:1")
        #expect(error("div:0") == "div needs a number other than 0, as in div:1000")
        #expect(error("rate|default:—") == nil)
    }
}
