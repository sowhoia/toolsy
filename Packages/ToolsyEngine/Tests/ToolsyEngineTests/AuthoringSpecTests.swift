import Foundation
import Testing
@testable import ToolsyEngine
@testable import ToolsyShared

/// docs/MOD_AUTHORING_FOR_AI.md is read by models that follow it literally, so it must stay true: its
/// examples are the tested files themselves, and everything the format knows appears in it. What the code
/// can enumerate is enumerated; where it offers no list, the literal list names the file it mirrors.
@Suite struct AuthoringSpecTests {
    private let document: Documentation

    init() throws {
        document = try Documentation(Documentation.authoringSpecification)
    }

    // MARK: - Examples

    /// The examples made by `toolsy-mod new`: the id each is written with and its template.
    private static let templateExamples = [
        ("uptime", "basic"), ("hide-folder", "switch"), ("load-chart", "service"), ("battery-tile", "widget"),
    ]

    /// The document's copy of `path`, which must exist exactly once.
    private func block(_ path: String) -> Documentation.Block? {
        let found = document.blocks.filter { $0.path == path }
        #expect(found.count == 1, "\(path) is shown \(found.count) times")
        return found.first
    }

    /// Every file `new` writes (but its README) is in the document as written, for every template `new` has.
    @Test func templateExamplesAreWhatNewWrites() async throws {
        let usage = try await toolsyMod(["help", "new"]).output
        let templates = try #require(usage.firstMatch(of: /--template ([a-z|]+)/)).1.split(separator: "|").map(String.init)
        #expect(Set(templates) == Set(Self.templateExamples.map(\.1)), "every template is a worked example")

        let directory = try TemporaryDirectory()
        for (id, template) in Self.templateExamples {
            #expect(try await toolsyMod(["new", id, "--template", template], in: directory.url).status == 0)
            let folder = directory.url.appending(path: id, directoryHint: .isDirectory)
            let files = try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false)).filter { $0 != "README.md" }
            #expect(files.count >= 2)
            for file in files {
                let written = try String(contentsOf: folder.appending(path: file), encoding: .utf8)
                #expect(block("\(id)/\(file)")?.body == written, "\(id)/\(file) differs from what toolsy-mod new writes")
            }
        }
    }

    /// Keep Awake as shipped: its manifest and every file under scripts/, which is what its build.sh packs.
    @Test func keepAwakeIsTheShippedMod() throws {
        let folder = DocumentedManifestTests.repository.appending(path: "Mods/keep-awake", directoryHint: .isDirectory)
        let scripts = try FileManager.default.contentsOfDirectory(atPath: folder.appending(path: "scripts").path(percentEncoded: false))
        for file in ["mod.json"] + scripts.map({ "scripts/\($0)" }) {
            let shipped = try String(contentsOf: folder.appending(path: file), encoding: .utf8)
            #expect(block("keep-awake/\(file)")?.body == shipped, "keep-awake/\(file) differs from Mods/keep-awake/\(file)")
        }
    }

    /// Blocks labelled with a path that is no tested file form a mod of their own (`disk-free`), which must
    /// install and whose command must report a patch.
    @Test func illustrationModWorks() async throws {
        let examples = Set(Self.templateExamples.map(\.0) + ["keep-awake"])
        let others = document.blocks.compactMap { block in block.path.map { ($0, block.body) } }
            .filter { !examples.contains(String($0.0.prefix { $0 != "/" })) }
        #expect(Set(others.map { String($0.0.prefix { $0 != "/" }) }) == ["disk-free"])
        let directory = try TemporaryDirectory()
        for (path, body) in others {
            try directory.write(body, to: path, executable: path.hasSuffix(".sh"))
        }
        let folder = directory.url.appending(path: "disk-free", directoryHint: .isDirectory)
        #expect(try await ModPackage.validate(folder).id == "disk-free")
        // macOS checks a program on its first start, which on a busy Mac has taken longer than the command's
        // 10 s timeout. That start happens here, so the run below measures what the mod does.
        _ = try await ProcessRunner.run(ProcessRunner.Request(executable: folder.appending(path: "scripts/read.sh"), timeout: 120))
        let result = try await toolsyMod(["run", folder.path(percentEncoded: false), "read", "--locale", "en", "--json"])
        let report = try JSONDecoder().decode(RunJSON.self, from: Data(result.output.utf8))
        #expect(report.ok && report.notes.isEmpty, "\(result.output)")
        #expect(Set((report.output?.patch ?? [:]).keys) == ["free", "status", "level"], "\(result.output)")
    }

    // MARK: - Form

    @Test func everyBlockNamesItsLanguage() {
        let blocks = document.blocks
        #expect(blocks.count > 30)
        #expect(blocks.allSatisfy { !$0.language.isEmpty })
    }

    /// A model copies what it reads: an escaped `\|` in a table would be copied into a template.
    @Test func noEscapedPipes() {
        #expect(!document.text.contains(#"\|"#))
    }

    /// Every link to a heading of the document leads to one (GitHub's anchors: lowercase, punctuation dropped).
    @Test func linksLeadToHeadings() {
        var inBlock = false
        var anchors: Set<String> = []
        for line in document.text.split(separator: "\n") {
            if line.hasPrefix("```") { inBlock.toggle() }
            guard !inBlock, let heading = line.firstMatch(of: /^#{1,6} (.+)$/) else { continue }
            anchors.insert(String(heading.1.lowercased().filter { $0.isLetter || $0.isNumber || $0 == " " || $0 == "-" || $0 == "_" })
                .replacing(" ", with: "-"))
        }
        let links = document.text.matches(of: /\]\(#([^)]+)\)/).map { String($0.1) }
        #expect(links.count > 30)
        #expect(Set(links).subtracting(anchors).isEmpty, "\(Set(links).subtracting(anchors).sorted())")
    }

    // MARK: - Coverage

    /// The line of a reference table whose first cell is, or starts with, `` `name` ``.
    private func row(_ name: String, in text: String) -> String? {
        text.split(separator: "\n").first { $0.hasPrefix("| `\(name)` ") || $0.hasPrefix("| `\(name)`,") }.map(String.init)
    }

    /// The stored properties of a decoded value: for the format's types, its JSON field names. `Any`, since
    /// Mirror reflects values of every type.
    private static func fields(of value: Any) -> [String] {
        Mirror(reflecting: value).children.compactMap(\.label)
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    /// Control types, mirroring `ModControl.Kind` in ToolsyShared/ModControl.swift, each with the smallest JSON
    /// it decodes from. Every field of each type is named in that type's row of the Interface tables.
    private static let controls: [(type: String, json: String)] = [
        ("section", #"{"type": "section", "children": []}"#),
        ("row", #"{"type": "row", "children": []}"#),
        ("divider", #"{"type": "divider"}"#),
        ("toggle", #"{"type": "toggle", "label": "a", "bind": "a"}"#),
        ("slider", #"{"type": "slider", "label": "a", "bind": "a", "min": 0, "max": 1}"#),
        ("stepper", #"{"type": "stepper", "label": "a", "bind": "a"}"#),
        ("picker", #"{"type": "picker", "bind": "a", "options": ["a"]}"#),
        ("input", #"{"type": "input", "bind": "a"}"#),
        ("button", #"{"type": "button", "label": "a", "command": "a"}"#),
        ("value", #"{"type": "value", "label": "a", "value": "a"}"#),
        ("stat", #"{"type": "stat", "label": "a", "value": "a"}"#),
        ("text", #"{"type": "text", "text": "a"}"#),
        ("gauge", #"{"type": "gauge", "label": "a", "bind": "a"}"#),
        ("chart", #"{"type": "chart", "series": [{"bind": "a"}]}"#),
        ("list", #"{"type": "list", "bind": "a"}"#),
    ]

    @Test func everyControlAndFieldIsDescribed() throws {
        let interface = document.section("Interface")
        for (type, json) in Self.controls {
            let control = try Self.decode(ModControl.self, json)
            // The case of the kind is the JSON type and its payload's properties are the type's fields; a
            // divider has no payload.
            let payload = Mirror(reflecting: control.kind).children.first
            #expect((payload?.label ?? "divider") == type)
            let line = try #require(row(type, in: interface), "no row for \(type)")
            for field in payload.map({ Self.fields(of: $0.value) }) ?? [] {
                #expect(line.contains("`\(field)`"), "\(type).\(field) is not in its row")
            }
            for field in Self.fields(of: control) where field != "kind" {
                #expect(row(field, in: interface) != nil, "the common field \(field)")
            }
        }
        let option = ModControl.Picker.Option(value: "a", label: "a")
        let series = try Self.decode(ModControl.Chart.Series.self, #"{"bind": "a"}"#)
        for field in Self.fields(of: option) + Self.fields(of: series) {
            #expect(interface.contains("\"\(field)\""), "\(field) of picker options and chart series")
        }
    }

    @Test func everyManifestFieldIsDescribed() throws {
        let manifest = try ModManifest.load(from: Data(#"{"schema": 1, "id": "a", "name": "A", "version": "1"}"#.utf8))
        let section = document.section("Manifest")
        for field in Self.fields(of: manifest) {
            #expect(row(field, in: section) != nil, "the manifest field \(field)")
        }
    }

    @Test func everyCommandFieldAndVariableIsDescribed() throws {
        let section = document.section("Commands")
        let command = try Self.decode(ModCommand.self, #"{"shell": "true"}"#)
        for field in Self.fields(of: command).flatMap({ $0 == "program" ? ["exec", "shell"] : [$0] }) {
            #expect(row(field, in: section) != nil, "the command field \(field)")
        }
        let input = CommandInput(event: .command, command: "c", key: "k", value: 1, state: ["key": 1], locale: "ru")
        let directory = URL(filePath: "/tmp")
        var names: Set<String> = []
        for privileged in [false, true] {
            names.formUnion(CommandEnvironment.variables(modID: "a", modDirectory: directory, dataDirectory: directory,
                                                         input: input, privileged: privileged).keys)
        }
        let environment = document.section("Environment")
        for name in names.map({ $0 == "TOOLSY_STATE_key" ? "TOOLSY_STATE_<key>" : $0 }) {
            #expect(environment.contains("| `\(name)`") || environment.contains(", `\(name)`"), "the variable \(name)")
        }
    }

    /// `TOOLSY_EVENT` values, mirroring `ModEvent` in ToolsyShared/CommandContract.swift.
    private static let commandEvents = ["enable", "disable", "uninstall", "refresh", "service", "command", "launch", "wake", "network", "power"]

    @Test func everyLifecyclePieceAndEventIsDescribed() throws {
        let lifecycle = try Self.decode(ModLifecycle.self, #"{"refresh": {"command": "a"}}"#)
        let section = document.section("Lifecycle")
        for hook in Self.fields(of: lifecycle) {
            #expect(row(hook, in: section) != nil, "the hook \(hook)")
        }
        let refresh = try #require(row("refresh", in: section))
        for field in Self.fields(of: try #require(lifecycle.refresh)) {
            #expect(refresh.contains("`\(field)`"), "refresh.\(field)")
        }
        let events = document.section("System events")
        for event in ModSystemEvent.allCases {
            #expect(row(event.rawValue, in: events) != nil, "the event \(event)")
        }
        let variable = try #require(document.section("Environment").split(separator: "\n").first { $0.hasPrefix("| `TOOLSY_EVENT`") })
        for event in Self.commandEvents {
            #expect(try Self.decode(ModEvent.self, "\"\(event)\"").rawValue == event)
            #expect(variable.contains("`\(event)`"), "TOOLSY_EVENT \(event)")
        }
    }

    @Test func everyHostKeyIsDescribed() {
        let section = document.section("State")
        for key in ReservedStateKey.all {
            #expect(row(key, in: section) != nil, "the host key \(key)")
        }
    }

    @Test func everyWidgetFieldIsDescribed() throws {
        let widget = try Self.decode(ModWidget.self, #"{"id": "a", "value": "a", "chart": {"series": []}, "gauge": {"bind": "a"}}"#)
        let section = document.section("Widgets")
        for field in Self.fields(of: widget) {
            #expect(row(field, in: section) != nil, "the widget field \(field)")
        }
        for (name, part) in [("chart", widget.chart as Any), ("gauge", widget.gauge as Any)] {
            let line = try #require(row(name, in: section))
            for field in Self.fields(of: try #require(Mirror(reflecting: part).children.first?.value)) {
                #expect(line.contains("`\(field)`"), "widget \(name).\(field)")
            }
        }
        let size = try #require(row("size", in: section))
        for value in ModWidget.Size.allCases {
            #expect(size.contains("`\"\(value.rawValue)\"`"), "size \(value)")
        }
    }

    /// Filters, mirroring `ModTemplate.Filter.init` in ToolsyEngine/Templates.swift, as the table names them.
    private static let filters = [
        "bytes", "rate", "bitrate", "percent", "duration", "round", "fixed:N", "number", "time", "date", "ago",
        "mul:N", "div:N", "add:N", "upper", "lower", "truncate:N", "count", "join:SEP", "either:A:B", "default:TEXT",
    ]

    @Test func everyFilterIsDescribed() throws {
        let section = document.section("Templates")
        for filter in Self.filters {
            let sample = filter.replacing("N", with: "2").replacing("SEP", with: "/").replacing("A:B", with: "a:b").replacing("TEXT", with: "x")
            #expect(throws: Never.self, "\(filter) is a filter") { try ModTemplate("{{v|\(sample)}}") }
            #expect(row(filter, in: section) != nil, "the filter \(filter)")
        }
        #expect(throws: SyntaxError.self) { try ModTemplate("{{v|unknownfilter}}") }
    }

    /// Operators and keywords, mirroring the tokenizer and parser in ToolsyEngine/Expressions.swift.
    private static let operators = ["||", "&&", "!", "==", "!=", "<", "<=", ">", ">=", "contains", "+", "-", "*", "/", "%"]
    private static let keywords = ["true", "false", "null"]

    @Test func everyOperatorIsDescribed() throws {
        let section = document.section("Expressions")
        for symbol in Self.operators {
            let sample = symbol == "!" ? "!a" : "a \(symbol) b"
            #expect(throws: Never.self, "\(symbol)") { try ModExpression(sample) }
            #expect(section.contains("`\(symbol)`"), "the operator \(symbol)")
        }
        for keyword in Self.keywords {
            #expect(throws: Never.self, "\(keyword)") { try ModExpression("a == \(keyword)") }
            #expect(section.contains("`\(keyword)`"), "the literal \(keyword)")
        }
    }

    /// Colour names, mirroring the list in toolsy-mod/PreviewCommand.swift and the app's Tint.swift.
    private static let colours = ["red", "orange", "yellow", "green", "mint", "teal", "cyan", "blue", "indigo", "purple", "pink", "brown", "gray"]

    @Test func everyColourIsDescribed() {
        let section = document.section("Colours")
        for colour in Self.colours + ModLevel.allCases.map(\.rawValue) {
            #expect(section.contains("`\(colour)`"), "the colour \(colour)")
        }
    }

    /// Every command of toolsy-mod and every option its help names.
    @Test func everyToolCommandAndOptionIsDescribed() async throws {
        let section = document.section("toolsy-mod")
        let overview = try await toolsyMod(["help"]).output
        let commands = overview.matches(of: #/(?m)^  ([a-z]+) /#).map { String($0.1) }
        #expect(commands.count >= 6)
        for command in commands {
            #expect(section.contains("| `\(command) "), "the command \(command)")
            let help = try await toolsyMod(["help", command]).output
            for option in Set(help.matches(of: /(?:^|[\s\[])(--?[a-z][a-z-]*)/).map { String($0.1) }) {
                // Named in a code span of its own or inside a synopsis: `--for <seconds>`, `[-o <folder>]`.
                let named = try Regex("[`\\[]\(NSRegularExpression.escapedPattern(for: option))[` \\]=]")
                #expect(section.contains(named), "\(command) \(option)")
            }
        }
    }

    /// Each kind of warning, as `ModManifest.warnings(files:)` words it, is in the warnings table.
    @Test func everyWarningIsDescribed() throws {
        let manifest = try ModManifest.load(from: Data(#"""
            {"schema": 1, "id": "a", "name": "A", "version": "1",
             "settings": {"t": 1, "s": "x", "l": -1, "h": 99, "p": "1", "i": []},
             "commands": {"m": {"shell": "scripts/missing.sh"}, "n": {"shell": "scripts/plain.sh"}},
             "ui": [{"type": "toggle", "label": "T", "bind": "t"}, {"type": "slider", "label": "S", "bind": "s", "min": 0, "max": 1},
                    {"type": "slider", "label": "L", "bind": "l", "min": 0, "max": 1}, {"type": "stepper", "label": "H", "bind": "h", "max": 10},
                    {"type": "picker", "bind": "p", "options": [{"value": 1}]}, {"type": "input", "bind": "i"}],
             "localizations": {"ru": {"Gone": "Нет"}}}
            """#.utf8))
        let payload = try ModPayload(files: ["mod.json": Data(), "scripts/plain.sh": Data()], executables: [])
        let warnings = manifest.warnings(files: payload)
        #expect(warnings.count == 9, "\(warnings)")
        let table = document.section("Warnings")
        let phrases = [
            "which is not a file of the mod", "which is not executable (chmod +x)", "is not true or false; the toggle shows it as off",
            "is not a number; the slider shows its minimum", "is below the slider's min", "above the",
            "matches the value of none of the options", "is not text, a number or a boolean; the field shows nothing",
            "is not the text of any translated field, so this entry is never used",
        ]
        for phrase in phrases {
            #expect(warnings.contains { $0.contains(phrase) }, "\(phrase) is no longer what validate says")
            #expect(table.contains(phrase), "the warning \(phrase)")
        }
    }

    /// The Limits table states the code's constants.
    @Test func limitsAreTheCodes() {
        let section = document.section("Limits")
        let timing = EngineTiming()
        let rows = [
            "| Files in a mod | \(ModPayload.maxFileCount) |",
            "| Total size of a mod | \(ModPayload.maxTotalBytes / 1024 / 1024) MB |",
            "| Command `timeout` | \(Int(ModCommand.defaultTimeout)) s by default, at most \(Int(ModCommand.maxTimeout)) s |",
            "| Grace between `SIGTERM` and `SIGKILL` | \(timing.killGrace.components.seconds) s |",
            "| Standard output and standard error read per command | \(ProcessRunner.Request(executable: URL(filePath: "/")).outputLimit / 1024 / 1024) MB each |",
            "| One line of the service | \(ServiceProcess.maxLineLength / 1024) KB |",
            "| Controls in `ui`, all widgets' `detail` and `quick` together | \(ModManifest.maxControls) |",
            "| Quick controls | \(ModManifest.maxQuickControls) |",
            "| Nesting of controls | \(ModManifest.maxNesting) levels |",
            "| Options of a picker | \(ModControl.Picker.maxOptions) |",
            "| Points of a chart / of a widget chart | 2–600, default \(ModControl.Chart.defaultPoints) / 2–120, default \(ModWidget.Chart.defaultPoints) |",
            "| Widgets per mod | \(ModManifest.maxWidgets) |",
            "| Languages / entries per language | \(ModManifest.maxLanguages) / \(ModManifest.maxTranslations) |",
            "| Notification title / body | \(ModNotification.maxTitleLength) / \(ModNotification.maxBodyLength) characters |",
            "| Notifications per mod | 1 every \(timing.notificationInterval.components.seconds) s; identical ones 1 per \(timing.repeatedNotificationWindow.components.seconds) s |",
        ]
        for row in rows {
            #expect(section.contains(row), "\(row)")
        }
    }
}
