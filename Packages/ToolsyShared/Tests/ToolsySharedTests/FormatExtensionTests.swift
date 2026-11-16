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

private func ui(_ controls: String) -> String {
    failure(minimal(#""commands": {"go": {"shell": "true"}}, "ui": [\#(controls)]"#))
}

private func widgets(_ widgets: String) -> String {
    failure(minimal(#""commands": {"go": {"shell": "true"}}, "widgets": [\#(widgets)]"#))
}

@Suite struct WidgetValidationTests {
    @Test func decodesAWidget() throws {
        let mod = try manifest(minimal(#"""
        "commands": {"go": {"shell": "true"}},
        "widgets": [
            {"id": "load", "title": "Load", "icon": "cpu", "value": "{{load|percent}}", "tint": "{{level}}", "size": "medium",
             "chart": {"series": [{"bind": "load"}], "style": "line", "points": 60, "min": 0, "max": 100}, "when": "enabled",
             "detail": [{"type": "button", "label": "Go", "command": "go"}]},
            {"id": "disk", "value": "{{free|bytes}}", "gauge": {"bind": "used"}}
        ]
        """#))
        #expect(mod.widgets.map(\.id) == ["load", "disk"])
        #expect(mod.widgets[0].size == .medium && mod.widgets[0].chart?.points == 60 && mod.widgets[0].detail.count == 1)
        #expect(mod.widgets[1].size == .small && mod.widgets[1].chart == nil)
        #expect(mod.widgets[1].gauge?.min == 0 && mod.widgets[1].gauge?.max == 100)
    }

    @Test func checksIdentifiers() {
        for id in ["", "Load", "-a", "_a", "a.b", "a b", String(repeating: "a", count: 33)] {
            #expect(widgets(#"{"id": "\#(id)", "value": "x"}"#)
                == #"widgets[0].id: "\#(id)" is invalid: use 1–32 lowercase letters, digits, "_" or "-", starting with a letter or digit"#)
        }
        #expect(widgets(#"{"id": "0a_b-c", "value": "x"}, {"id": "\#(String(repeating: "z", count: 32))", "value": "x"}"#) == "no error")
        #expect(widgets(#"{"id": "a", "value": "x"}, {"id": "a", "value": "y"}"#) == #"widgets[1].id: "a" is used by another widget"#)
        let nine = (0..<9).map { #"{"id": "w\#($0)", "value": "x"}"# }.joined(separator: ", ")
        #expect(widgets(nine) == "widgets: a mod offers at most 8 widgets")
    }

    @Test func checksValueChartAndGauge() {
        #expect(widgets(#"{"id": "a", "value": "  "}"#) == "widgets[0].value: must not be empty")
        #expect(widgets(#"{"id": "a", "value": "x", "chart": {"series": [{"bind": "a"}]}, "gauge": {"bind": "b"}}"#)
            == #"widgets[0]: a widget shows at most one of "chart" and "gauge""#)
        #expect(widgets(#"{"id": "a", "value": "x"}, {"id": "b", "value": "x", "chart": {"series": []}}"#)
            == "widgets[1].chart: a chart needs 1–3 series")
        let four = Array(repeating: #"{"bind": "a"}"#, count: 4).joined(separator: ", ")
        #expect(widgets(#"{"id": "a", "value": "x", "chart": {"series": [\#(four)]}}"#) == "widgets[0].chart: a chart needs 1–3 series")
        #expect(widgets(#"{"id": "a", "value": "x", "chart": {"series": [{"bind": "no way"}]}}"#)
            == #"widgets[0].chart: bind "no way" is not a valid key"#)
        #expect(widgets(#"{"id": "a", "value": "x", "chart": {"series": [{"bind": "a"}], "points": 1}}"#)
            == "widgets[0].chart: points must be between 2 and 120")
        #expect(widgets(#"{"id": "a", "value": "x", "chart": {"series": [{"bind": "a"}], "points": 121}}"#)
            == "widgets[0].chart: points must be between 2 and 120")
        #expect(widgets(#"{"id": "a", "value": "x", "chart": {"series": [{"bind": "a"}], "points": 120, "min": 1, "max": 1}}"#)
            == "widgets[0].chart: min must be less than max")
        #expect(widgets(#"{"id": "a", "value": "x", "chart": {"series": [{"bind": "a"}], "points": 2, "max": 1}}"#) == "no error")
        #expect(widgets(#"{"id": "a", "value": "x", "gauge": {"bind": "1x"}}"#) == #"widgets[0].gauge: bind "1x" is not a valid key"#)
        #expect(widgets(#"{"id": "a", "value": "x", "gauge": {"bind": "a", "min": 5, "max": 0}}"#)
            == "widgets[0].gauge: min must be less than max")
        #expect(widgets(#"{"id": "a", "value": "x", "size": "huge"}"#).hasPrefix("widgets[0].size:"))
    }

    @Test func checksTheDetailLikeTheChildrenOfASection() {
        #expect(widgets(#"{"id": "a", "value": "x", "detail": [{"type": "toggle", "label": "T", "bind": "t", "command": "nope"}]}"#)
            == #"widgets[0].detail[0]: command "nope" is not defined"#)
        #expect(widgets(#"{"id": "a", "value": "x", "detail": [{"type": "row", "children": [{"type": "toggle", "label": "T", "bind": "enabled"}]}]}"#)
            == #"widgets[0].detail[0].children[0]: "enabled" is managed by the host and cannot be bound to an input"#)
        // A top-level section's children sit at depth 2, so two more levels of sections fit below them.
        let deepest = #"{"type": "section", "children": [{"type": "section", "children": [{"type": "divider"}]}]}"#
        #expect(widgets(#"{"id": "a", "value": "x", "detail": [\#(deepest)]}"#) == "no error")
        let tooDeep = #"{"type": "section", "children": [\#(deepest)]}"#
        #expect(widgets(#"{"id": "a", "value": "x", "detail": [\#(tooDeep)]}"#)
            == "widgets[0].detail[0].children[0].children[0].children: controls are nested deeper than 4 levels")
    }

    @Test func detailControlsCountTowardTheManifestLimit() {
        let dividers = { (count: Int) in Array(repeating: #"{"type": "divider"}"#, count: count).joined(separator: ", ") }
        let full = minimal(#""ui": [\#(dividers(150))], "widgets": [{"id": "a", "value": "x", "detail": [\#(dividers(50))]}]"#)
        #expect(failure(full) == "no error")
        let over = minimal(#""ui": [\#(dividers(150))], "widgets": [{"id": "a", "value": "x", "detail": [\#(dividers(51))]}]"#)
        #expect(failure(over) == "widgets[0].detail: more than 200 controls in ui and the widgets' details together")
    }
}

@Suite struct SystemEventTests {
    @Test func decodesEvents() throws {
        let mod = try manifest(minimal(#"""
        "commands": {"sync": {"shell": "true"}, "check": {"shell": "true", "privileged": true}},
        "lifecycle": {"events": {"launch": "sync", "wake": "sync", "network": "check", "power": "sync"}}
        """#))
        #expect(mod.lifecycle.events == [.launch: "sync", .wake: "sync", .network: "check", .power: "sync"])
        #expect(!mod.lifecycle.hasToggle, "events alone do not give a mod a switch")
        #expect(try manifest(minimal()).lifecycle.events.isEmpty)
    }

    @Test func rejectsBrokenEvents() {
        #expect(failure(minimal(#""lifecycle": {"events": {"wake": "missing"}}"#)) == #"lifecycle.events.wake: command "missing" is not defined"#)
        #expect(failure(minimal(#""commands": {"s": {"shell": "true"}}, "lifecycle": {"events": {"boot": "s"}}"#))
            == #"lifecycle.events: unknown event "boot"; expected one of "launch", "wake", "network", "power""#)
        #expect(failure(minimal(#""commands": {"s": {"shell": "true"}}, "lifecycle": {"service": "s", "events": {"power": "s"}}"#))
            == "lifecycle.events.power: the service command cannot also be an event command")
    }
}

@Suite struct NotifyKeyTests {
    @Test func notifyIsNeverState() {
        #expect(failure(minimal(#""settings": {"notify": "x"}"#)) == #"settings: "notify" is reserved for the host"#)
        #expect(ui(#"{"type": "input", "bind": "notify"}"#) == #"ui[0]: bind "notify" is not state: a patch's notify is shown, never stored"#)
        #expect(ui(#"{"type": "gauge", "label": "G", "bind": "notify"}"#)
            == #"ui[0]: bind "notify" is not state: a patch's notify is shown, never stored"#)
        #expect(ui(#"{"type": "list", "bind": "notify"}"#).contains("never stored"))
        #expect(ui(#"{"type": "chart", "series": [{"bind": "notify"}]}"#).contains("never stored"))
        #expect(widgets(#"{"id": "a", "value": "x", "gauge": {"bind": "notify"}}"#)
            == #"widgets[0].gauge: bind "notify" is not state: a patch's notify is shown, never stored"#)
        #expect(failure(minimal(#""commands": {"x": {"shell": "true", "capture": "notify"}}"#))
            == #"commands.x: capture "notify" is not a usable state key"#)
    }
}

@Suite struct NewControlTests {
    @Test func decodesNewFields() throws {
        let mod = try manifest(minimal(#"""
        "ui": [
            {"type": "section", "title": "More", "collapsible": true, "collapsed": true, "help": "Folded at first", "children": [
                {"type": "row", "children": [{"type": "stat", "label": "Up", "value": "{{up}}", "icon": "arrow.up", "tint": "green"}]},
                {"type": "button", "label": "Copy", "copy": "{{ip}}", "help": "Copies the address"},
                {"type": "picker", "bind": "iface", "optionsFrom": "interfaces"},
                {"type": "gauge", "label": "Disk", "bind": "used", "format": "bytes"},
                {"type": "chart", "series": [{"bind": "rx"}], "format": "div:1000|fixed:1"}
            ]},
            {"type": "section", "children": []}
        ]
        """#))
        guard case .section(let section) = mod.ui[0].kind, case .section(let plain) = mod.ui[1].kind,
              case .row(let row) = section.children[0].kind, case .stat(let stat) = row.children[0].kind,
              case .button(let button) = section.children[1].kind, case .picker(let picker) = section.children[2].kind,
              case .gauge(let gauge) = section.children[3].kind, case .chart(let chart) = section.children[4].kind
        else {
            Issue.record("controls decoded into unexpected kinds")
            return
        }
        #expect(section.collapsible && section.collapsed && !plain.collapsible && !plain.collapsed)
        #expect(mod.ui[0].help == "Folded at first" && section.children[1].help == "Copies the address" && mod.ui[1].help == nil)
        #expect(stat == ModControl.Stat(label: "Up", value: "{{up}}", icon: "arrow.up", tint: "green"))
        #expect(button.copy == "{{ip}}" && button.command == nil && button.open == nil)
        #expect(picker.optionsFrom == "interfaces" && picker.options.isEmpty)
        #expect(gauge.format == "bytes" && chart.format == "div:1000|fixed:1")
    }

    @Test func rejectsBrokenNewFields() {
        #expect(ui(#"{"type": "section", "collapsible": true, "children": []}"#) == "ui[0]: a collapsible section needs a title")
        #expect(ui(#"{"type": "section", "title": "T", "collapsed": true, "children": []}"#) == #"ui[0]: collapsed needs "collapsible": true"#)
        #expect(ui(#"{"type": "section", "title": "T", "collapsible": false, "collapsed": true, "children": []}"#)
            == #"ui[0]: collapsed needs "collapsible": true"#)
        #expect(ui(#"{"type": "stat", "label": "L"}"#) == #"ui[0]: missing required field "value""#)
        let oneOf = #"ui[0]: a button needs exactly one of "command", "open" and "copy""#
        #expect(ui(#"{"type": "button", "label": "B"}"#) == oneOf)
        #expect(ui(#"{"type": "button", "label": "B", "command": "go", "copy": "x"}"#) == oneOf)
        #expect(ui(#"{"type": "button", "label": "B", "open": "https://example.com", "copy": "x"}"#) == oneOf)
        let pickerOneOf = #"ui[0]: a picker needs exactly one of "options" and "optionsFrom""#
        #expect(ui(#"{"type": "picker", "bind": "p"}"#) == pickerOneOf)
        #expect(ui(#"{"type": "picker", "bind": "p", "options": ["a"], "optionsFrom": "list"}"#) == pickerOneOf)
        #expect(ui(#"{"type": "picker", "bind": "p", "options": [], "optionsFrom": "list"}"#) == pickerOneOf)
        #expect(ui(#"{"type": "picker", "bind": "p", "optionsFrom": "my list"}"#) == #"ui[0]: optionsFrom "my list" is not a valid key"#)
        #expect(ui(#"{"type": "picker", "bind": "p", "options": []}"#) == "ui[0]: a picker needs 1–32 options")
    }
}

@Suite struct PickerOptionsFromStateTests {
    @Test func readsStringsAndObjects() {
        let options = ModControl.Picker.Option.options(from: [
            "en0",
            ["value": 2, "label": "Two", "icon": "2.circle"],
            ["value": true],
            ["value": "x", "label": "Ex"],
        ])
        #expect(options == [
            .init(value: "en0", label: "en0"),
            .init(value: 2, label: "Two", icon: "2.circle"),
            .init(value: true, label: "true"),
            .init(value: "x", label: "Ex"),
        ])
    }

    @Test func skipsMalformedElements() {
        let options = ModControl.Picker.Option.options(from: [
            7, true, nil, ["nested"],
            ["label": "no value"], ["value": nil], ["value": [1]], ["value": ["k": 1]],
            ["value": 1, "label": 5], ["value": 1, "icon": false],
            "kept",
        ])
        #expect(options.map(\.label) == ["kept"])
    }

    @Test func capsAndToleratesMissingValues() {
        let many = JSONValue.array((0..<40).map { .string("o\($0)") })
        #expect(ModControl.Picker.Option.options(from: many).map(\.label) == (0..<32).map { "o\($0)" })
        #expect(ModControl.Picker.Option.options(from: nil).isEmpty)
        #expect(ModControl.Picker.Option.options(from: "text").isEmpty)
        #expect(ModControl.Picker.Option.options(from: ["k": "v"]).isEmpty)
        #expect(ModControl.Picker.Option.options(from: []).isEmpty)
    }
}

@Suite struct LocalizationTests {
    private static let source = minimal(#"""
    "author": "Author", "summary": "Shows things", "icon": "star", "tint": "blue",
    "commands": {"go": {"shell": "true"}},
    "localizations": {
        "ru": {
            "Demo": "Демо", "Shows things": "Показывает", "Author": "Автор", "star": "звезда", "blue": "синий",
            "Main": "Главное", "Footer": "Подвал", "Tip": "Подсказка", "Toggle": "Переключатель", "Slider": "Ползунок", "%": " %",
            "Stepper": "Счётчик", " s": " с", "Picker": "Выбор", "One": "Один", "Input": "Поле", "Type here": "Пишите",
            "Button": "Кнопка", "{{ip}}": "IP {{ip}}", "Sure?": "Точно?", "Value": "Значение", "{{ms}} ms": "{{ms}} мс",
            "Stat": "Показатель", "Text": "Текст", "Gauge": "Шкала", "Chart": "График", "Series": "Ряд", " ms": " мс",
            "Nothing": "Пусто", "Tile": "Плитка", "{{load}}": "{{load}} %", "go": "иди", "enabled": "включён", "t": "т"
        },
        "pt": {"Demo": "Demonstração"},
        "pt-br": {"Demo": "Demonstração BR"},
        "de": {}
    },
    "ui": [
        {"type": "section", "title": "Main", "footer": "Footer", "help": "Tip", "when": "enabled", "children": [
            {"type": "toggle", "label": "Toggle", "bind": "t", "command": "go"},
            {"type": "slider", "label": "Slider", "bind": "s", "min": 0, "max": 1, "unit": "%"},
            {"type": "stepper", "label": "Stepper", "bind": "n", "unit": " s"},
            {"type": "picker", "label": "Picker", "bind": "p", "options": [{"value": "One", "label": "One"}, "Value"]},
            {"type": "input", "label": "Input", "bind": "i", "placeholder": "Type here"},
            {"type": "row", "children": [
                {"type": "button", "label": "Button", "command": "go", "value": "Value", "confirm": "Sure?"},
                {"type": "button", "label": "Button", "copy": "{{ip}}"}
            ]}
        ]},
        {"type": "value", "label": "Value", "value": "{{ms}} ms", "tint": "blue"},
        {"type": "stat", "label": "Stat", "value": "{{ms}} ms"},
        {"type": "text", "text": "Text"},
        {"type": "gauge", "label": "Gauge", "bind": "g", "unit": "%"},
        {"type": "chart", "label": "Chart", "series": [{"bind": "c", "label": "Series"}], "unit": " ms"},
        {"type": "list", "bind": "l", "empty": "Nothing"}
    ],
    "widgets": [{"id": "w", "title": "Tile", "value": "{{load}}", "icon": "star", "chart": {"series": [{"bind": "c", "label": "Series"}]},
                 "detail": [{"type": "text", "text": "Text"}]}]
    """#)

    @Test func translatesEveryUserVisibleText() throws {
        let mod = try manifest(Self.source)
        let ru = mod.localized(for: ["ru-RU", "en-US"])
        #expect(ru.name == "Демо" && ru.summary == "Показывает")
        #expect(ru.author == "Author" && ru.icon == "star" && ru.tint == "blue" && ru.id == "demo")
        #expect(ru.commands == mod.commands && ru.lifecycle == mod.lifecycle && ru.settings == mod.settings)

        guard case .section(let section) = ru.ui[0].kind,
              case .toggle(let toggle) = section.children[0].kind, case .slider(let slider) = section.children[1].kind,
              case .stepper(let stepper) = section.children[2].kind, case .picker(let picker) = section.children[3].kind,
              case .input(let input) = section.children[4].kind, case .row(let row) = section.children[5].kind,
              case .button(let run) = row.children[0].kind, case .button(let copy) = row.children[1].kind,
              case .value(let value) = ru.ui[1].kind, case .stat(let stat) = ru.ui[2].kind, case .text(let text) = ru.ui[3].kind,
              case .gauge(let gauge) = ru.ui[4].kind, case .chart(let chart) = ru.ui[5].kind, case .list(let list) = ru.ui[6].kind,
              case .text(let detail) = ru.widgets[0].detail[0].kind
        else {
            Issue.record("controls translated into unexpected kinds")
            return
        }
        #expect(section.title == "Главное" && section.footer == "Подвал" && ru.ui[0].help == "Подсказка" && ru.ui[0].when == "enabled")
        #expect(toggle.label == "Переключатель" && toggle.bind == "t" && toggle.command == "go")
        #expect(slider.label == "Ползунок" && slider.unit == " %")
        #expect(stepper.label == "Счётчик" && stepper.unit == " с")
        #expect(picker.label == "Выбор" && picker.options.map(\.label) == ["Один", "Значение"])
        #expect(picker.options.map(\.value) == ["One", "Value"], "option values are data, not text")
        #expect(input.label == "Поле" && input.placeholder == "Пишите")
        #expect(run.label == "Кнопка" && run.confirm == "Точно?" && run.value == "Value")
        #expect(copy.copy == "IP {{ip}}")
        #expect(value.label == "Значение" && value.value == "{{ms}} мс" && value.tint == "blue")
        #expect(stat.label == "Показатель" && stat.value == "{{ms}} мс")
        #expect(text.text == "Текст" && detail.text == "Текст")
        #expect(gauge.label == "Шкала" && gauge.unit == " %" && gauge.bind == "g")
        #expect(chart.label == "График" && chart.unit == " мс" && chart.series[0].label == "Ряд" && chart.series[0].bind == "c")
        #expect(list.empty == "Пусто")
        #expect(ru.widgets[0].title == "Плитка" && ru.widgets[0].value == "{{load}} %" && ru.widgets[0].icon == "star")
        #expect(ru.widgets[0].chart?.series[0].label == "Ряд" && ru.widgets[0].id == "w")
    }

    @Test func picksTheFirstPreferredLanguageWithATable() throws {
        let mod = try manifest(Self.source)
        #expect(mod.localized(for: ["pt-BR"]).name == "Demonstração BR", "an exact region before the bare language")
        #expect(mod.localized(for: ["pt-PT"]).name == "Demonstração")
        #expect(mod.localized(for: ["pt"]).name == "Demonstração")
        #expect(mod.localized(for: ["fr-FR", "ru"]).name == "Демо", "a later language when the first has no table")
        #expect(mod.localized(for: ["ru_RU"]).name == "Демо")
        #expect(mod.localizationCode(for: ["zh-Hans-CN", "pt-BR"]) == "pt-br")
        #expect(mod.localizationCode(for: ["de-AT", "ru"]) == "de", "an empty table still counts as the language")
        #expect(mod.localized(for: ["de-AT", "ru"]) == mod)
    }

    @Test func returnsTheManifestUnchangedWithoutAMatch() throws {
        let mod = try manifest(Self.source)
        #expect(mod.localized(for: ["fr", "ja-JP"]) == mod)
        #expect(mod.localized(for: []) == mod)
        let plain = try manifest(minimal(#""ui": [{"type": "text", "text": "Hi"}]"#))
        #expect(plain.localizations.isEmpty)
        #expect(plain.localized(for: ["ru"]) == plain)
    }

    @Test func rejectsBrokenTables() {
        let badCode = #"is not a language code: use a lowercase BCP 47 language, optionally with a region, such as "ru" or "pt-br""#
        for code in ["RU", "pt_BR", "pt-BR", "r", "russian", "ru-", "ru-x", "ru-ru-ru", ""] {
            #expect(failure(minimal(#""localizations": {"\#(code)": {}}"#)) == #"localizations: "\#(code)" \#(badCode)"#, "\(code)")
        }
        for code in ["ru", "pt-br", "zh-hans", "es-419", "fil"] {
            #expect(failure(minimal(#""localizations": {"\#(code)": {"Demo": "x"}}"#)) == "no error", "\(code)")
        }
        let languages = (0..<21).map { index -> String in
            let letters = Array("abcdefghijklmnopqrstu")
            return #""a\#(letters[index])": {}"#
        }
        #expect(failure(minimal(#""localizations": {\#(languages.joined(separator: ", "))}"#)) == "localizations: at most 20 languages")
        let entries = (0..<501).map { #""s\#($0)": "t""# }.joined(separator: ", ")
        #expect(failure(minimal(#""localizations": {"ru": {\#(entries)}}"#)) == "localizations.ru: at most 500 entries")
        #expect(failure(minimal(#""localizations": {"ru": {"Demo": 5}}"#)).hasPrefix("localizations.ru.Demo:"))
    }

    @Test func translationsMustKeepTheManifestValid() {
        let long = String(repeating: "я", count: 81)
        #expect(failure(minimal(#""localizations": {"ru": {"Demo": "\#(long)"}}"#)) == "localizations.ru: name must be 1–80 characters")
        #expect(failure(minimal(#""widgets": [{"id": "a", "value": "Now"}], "localizations": {"ru": {"Now": " "}}"#))
            == "localizations.ru: widgets[0].value: must not be empty")
    }
}

@Suite struct LocaleVariableTests {
    private func variables(locale: String?, privileged: Bool = false) -> [String: String] {
        CommandEnvironment.variables(
            modID: "demo", modDirectory: URL(filePath: "/mods/demo"), dataDirectory: URL(filePath: "/data/demo"),
            input: CommandInput(event: .refresh, command: "status", state: [:], locale: locale), privileged: privileged
        )
    }

    @Test func passesWellFormedCodesLowercased() {
        #expect(variables(locale: "ru")["TOOLSY_LOCALE"] == "ru")
        #expect(variables(locale: "en-US")["TOOLSY_LOCALE"] == "en-us")
        #expect(variables(locale: "zh-Hans-CN", privileged: true)["TOOLSY_LOCALE"] == "zh-hans-cn")
        #expect(variables(locale: "es-419")["TOOLSY_LOCALE"] == "es-419")
    }

    @Test func dropsAnythingElse() {
        for locale in [nil, "", "r", "russian", "ru_RU", "ru-", "ru-RU;rm -rf /", "$(id)", "ru\nX=1", "ru-a", "ру"] {
            #expect(variables(locale: locale)["TOOLSY_LOCALE"] == nil, "\(String(describing: locale))")
            #expect(variables(locale: locale, privileged: true)["TOOLSY_LOCALE"] == nil)
        }
    }

    @Test func travelsInTheInput() throws {
        let input = CommandInput(event: .wake, command: "sync", state: [:], locale: "ru")
        let object = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(input))
        #expect(object == ["event": "wake", "command": "sync", "state": [:], "locale": "ru"])
        #expect(try JSONDecoder().decode(CommandInput.self, from: JSONEncoder().encode(input)) == input)
        let old = try JSONDecoder().decode(CommandInput.self, from: Data(#"{"event": "refresh", "command": "s", "state": {}}"#.utf8))
        #expect(old.locale == nil)
    }
}
