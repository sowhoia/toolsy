import Foundation

extension ModManifest {
    static let maxControls = 200
    static let maxNesting = 4
    static let maxWidgets = 8

    /// "1", "1.2" or "1.2.3" as three numbers, missing ones 0; nil for anything else.
    static func versionNumbers(_ text: String) -> [Int]? {
        guard text.wholeMatch(of: /[0-9]{1,4}(\.[0-9]{1,4}){0,2}/) != nil else { return nil }
        let numbers = text.split(separator: ".").compactMap { Int($0) }
        return numbers + Array(repeating: 0, count: 3 - numbers.count)
    }

    /// Checks everything decoding cannot: identifiers, cross-references, ranges and paths.
    /// The helper relies on it as well, so a manifest that passes is safe to snapshot and run.
    public func validate() throws {
        guard schema == Self.supportedSchema else {
            throw ManifestError("schema \(schema) is not supported by this version of Toolsy (expected \(Self.supportedSchema))")
        }
        guard Self.isValidID(id) else {
            throw ManifestError("id \"\(id)\" is invalid: use 1–64 lowercase letters, digits, \".\", \"_\" or \"-\", starting and ending with a letter or digit")
        }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 80 else {
            throw ManifestError("name must be 1–80 characters")
        }
        guard !version.isEmpty, version.count <= 32 else {
            throw ManifestError("version must be 1–32 characters")
        }
        if let toolsy {
            guard let required = Self.versionNumbers(toolsy) else {
                throw ManifestError("toolsy must be a version such as \"1.1\" or \"1.1.0\"")
            }
            // Its own version is three numbers by construction.
            if let current = Self.versionNumbers(ToolsyVersion.current), current.lexicographicallyPrecedes(required) {
                throw ManifestError("needs Toolsy \(toolsy) or later; this is Toolsy \(ToolsyVersion.current)")
            }
        }
        if let homepage, !Self.isWebURL(homepage) {
            throw ManifestError("homepage must be an http or https URL")
        }
        for key in settings.keys {
            guard Self.isValidKey(key) else {
                throw ManifestError("settings: \"\(key)\" is not a valid key")
            }
            guard !ReservedStateKey.all.contains(key) else {
                throw ManifestError("settings: \"\(key)\" is reserved for the host")
            }
        }
        for (name, command) in commands {
            try validate(command, named: name)
        }
        try validateLifecycle()
        var count = 0
        try validate(ui, path: "ui", depth: 1, count: &count)
        try validateWidgets(count: &count)
        try validateLocalizations()
    }

    public static func isValidID(_ id: String) -> Bool {
        id.wholeMatch(of: /[a-z0-9](?:[a-z0-9._-]{0,62}[a-z0-9])?/) != nil
    }

    /// State and settings keys. They double as `TOOLSY_STATE_<key>` variable names.
    public static func isValidKey(_ key: String) -> Bool {
        key.wholeMatch(of: /[A-Za-z_][A-Za-z0-9_]{0,63}/) != nil
    }

    static func isValidCommandName(_ name: String) -> Bool {
        name.wholeMatch(of: /[A-Za-z_][A-Za-z0-9_-]{0,63}/) != nil
    }

    static func isWebURL(_ string: String) -> Bool {
        guard let url = URL(string: string), let scheme = url.scheme?.lowercased(), url.host() != nil else {
            return false
        }
        return scheme == "http" || scheme == "https"
    }

    private func validate(_ command: ModCommand, named name: String) throws {
        let path = "commands.\(name)"
        guard Self.isValidCommandName(name) else {
            throw ManifestError("\(path): command names use letters, digits, \"_\" and \"-\"")
        }
        switch command.program {
        case .exec(let file):
            guard ModPayload.isSafeRelativePath(file) else {
                throw ManifestError("\(path): exec must be a relative path inside the mod")
            }
        case .shell(let script):
            guard !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ManifestError("\(path): shell must not be empty")
            }
        }
        guard command.timeout > 0, command.timeout <= ModCommand.maxTimeout else {
            throw ManifestError("\(path): timeout must be between 0 and \(Int(ModCommand.maxTimeout)) seconds")
        }
        if let capture = command.capture {
            // A captured string under `enabled` would be truthy even for the text "false"; `notify` is never stored.
            guard Self.isValidKey(capture), capture != ReservedStateKey.enabled, capture != ReservedStateKey.notify else {
                throw ManifestError("\(path): capture \"\(capture)\" is not a usable state key")
            }
        }
    }

    private func validateLifecycle() throws {
        let hooks = [
            ("enable", lifecycle.enable), ("disable", lifecycle.disable), ("uninstall", lifecycle.uninstall),
            ("service", lifecycle.service), ("refresh.command", lifecycle.refresh?.command),
        ]
        for (hook, name) in hooks {
            if let name { try requireCommand(name, at: "lifecycle.\(hook)") }
        }
        for event in ModSystemEvent.allCases {
            guard let name = lifecycle.events[event] else { continue }
            let path = "lifecycle.events.\(event.rawValue)"
            try requireCommand(name, at: path)
            // The service runs until it is stopped; as an event command it would be killed by its timeout.
            guard name != lifecycle.service else {
                throw ManifestError("\(path): the service command cannot also be an event command")
            }
        }
        if let name = lifecycle.service, let service = commands[name] {
            // The helper runs one-shot commands only and exits when idle; it cannot own a daemon.
            guard !service.privileged else {
                throw ManifestError("lifecycle.service: a service cannot be privileged")
            }
            guard service.capture == nil else {
                throw ManifestError("lifecycle.service: a service reports state as JSON lines and cannot use capture")
            }
            guard lifecycle.refresh?.command != name else {
                throw ManifestError("lifecycle.refresh: the service command cannot also be the refresh command")
            }
        }
        if let every = lifecycle.refresh?.every {
            guard every >= 1 else {
                throw ManifestError("lifecycle.refresh.every must be at least 1 second")
            }
        }
    }

    private func requireCommand(_ name: String, at path: String) throws {
        guard commands[name] != nil else {
            throw ManifestError("\(path): command \"\(name)\" is not defined")
        }
    }

    /// A key a control reads. `notify` is never stored, so reading it would always find nothing.
    private func requireKey(_ key: String, field: String = "bind", at path: String) throws {
        guard Self.isValidKey(key) else {
            throw ManifestError("\(path): \(field) \"\(key)\" is not a valid key")
        }
        guard key != ReservedStateKey.notify else {
            throw ManifestError("\(path): \(field) \"\(key)\" is not state: a patch's notify is shown, never stored")
        }
    }

    /// A control the user edits may not write the keys the host manages: flipping `enabled`
    /// from a bound toggle would bypass the `enable`/`disable` commands.
    private func requireEditableKey(_ key: String, at path: String) throws {
        try requireKey(key, at: path)
        guard !ReservedStateKey.all.contains(key) else {
            throw ManifestError("\(path): \"\(key)\" is managed by the host and cannot be bound to an input")
        }
    }

    private func validate(_ controls: [ModControl], path: String, depth: Int, count: inout Int) throws {
        guard depth <= Self.maxNesting else {
            throw ManifestError("\(path): controls are nested deeper than \(Self.maxNesting) levels")
        }
        for (index, control) in controls.enumerated() {
            count += 1
            guard count <= Self.maxControls else {
                throw ManifestError(path.hasPrefix("ui")
                    ? "ui: more than \(Self.maxControls) controls"
                    : "\(path): more than \(Self.maxControls) controls in ui and the widgets' details together")
            }
            try validate(control, path: "\(path)[\(index)]", depth: depth, count: &count)
        }
    }

    private func validate(_ control: ModControl, path: String, depth: Int, count: inout Int) throws {
        func command(_ name: String?) throws {
            if let name { try requireCommand(name, at: path) }
        }
        switch control.kind {
        case .section(let section):
            if section.collapsible {
                guard section.title != nil else { throw ManifestError("\(path): a collapsible section needs a title") }
            } else {
                guard !section.collapsed else {
                    throw ManifestError("\(path): collapsed needs \"collapsible\": true")
                }
            }
            try validate(section.children, path: "\(path).children", depth: depth + 1, count: &count)
        case .row(let row):
            guard (1...4).contains(row.children.count) else {
                throw ManifestError("\(path): a row holds 1–4 controls")
            }
            for child in row.children {
                switch child.kind {
                case .section, .row: throw ManifestError("\(path): a row cannot contain a section or another row")
                default: break
                }
            }
            try validate(row.children, path: "\(path).children", depth: depth + 1, count: &count)
        case .toggle(let toggle):
            try requireEditableKey(toggle.bind, at: path)
            try command(toggle.command)
        case .slider(let slider):
            try requireEditableKey(slider.bind, at: path)
            try command(slider.command)
            guard slider.min < slider.max else { throw ManifestError("\(path): min must be less than max") }
            if let step = slider.step {
                guard step > 0 else { throw ManifestError("\(path): step must be positive") }
            }
        case .stepper(let stepper):
            try requireEditableKey(stepper.bind, at: path)
            try command(stepper.command)
            guard stepper.step > 0 else { throw ManifestError("\(path): step must be positive") }
            if let min = stepper.min, let max = stepper.max {
                guard min < max else { throw ManifestError("\(path): min must be less than max") }
            }
        case .picker(let picker):
            try requireEditableKey(picker.bind, at: path)
            try command(picker.command)
            if let source = picker.optionsFrom {
                try requireKey(source, field: "optionsFrom", at: path)
            } else {
                guard (1...ModControl.Picker.maxOptions).contains(picker.options.count) else {
                    throw ManifestError("\(path): a picker needs 1–\(ModControl.Picker.maxOptions) options")
                }
            }
            guard picker.options.allSatisfy(\.value.isScalar) else {
                throw ManifestError("\(path): option values must be strings, numbers or booleans")
            }
        case .input(let input):
            try requireEditableKey(input.bind, at: path)
            try command(input.command)
        case .button(let button):
            try command(button.command)
            guard [button.command, button.open, button.copy].count(where: { $0 != nil }) == 1 else {
                throw ManifestError("\(path): a button needs exactly one of \"command\", \"open\" and \"copy\"")
            }
            if let open = button.open {
                guard Self.isWebURL(open) else { throw ManifestError("\(path): open must be an http or https URL") }
            }
        case .gauge(let gauge):
            try requireKey(gauge.bind, at: path)
            guard gauge.min < gauge.max else { throw ManifestError("\(path): min must be less than max") }
        case .chart(let chart):
            guard (1...6).contains(chart.series.count) else {
                throw ManifestError("\(path): a chart needs 1–6 series")
            }
            try chart.series.forEach { try requireKey($0.bind, at: path) }
            guard (2...600).contains(chart.points) else {
                throw ManifestError("\(path): points must be between 2 and 600")
            }
            if let min = chart.min, let max = chart.max {
                guard min < max else { throw ManifestError("\(path): min must be less than max") }
            }
        case .list(let list):
            try requireKey(list.bind, at: path)
            try command(list.command)
            if let limit = list.limit {
                guard limit > 0 else { throw ManifestError("\(path): limit must be positive") }
            }
        case .value, .stat, .text, .divider:
            break
        }
    }

    public static func isValidWidgetID(_ id: String) -> Bool {
        id.wholeMatch(of: /[a-z0-9][a-z0-9_-]{0,31}/) != nil
    }

    private func validateWidgets(count: inout Int) throws {
        guard widgets.count <= Self.maxWidgets else {
            throw ManifestError("widgets: a mod offers at most \(Self.maxWidgets) widgets")
        }
        var ids: Set<String> = []
        for (index, widget) in widgets.enumerated() {
            let path = "widgets[\(index)]"
            guard Self.isValidWidgetID(widget.id) else {
                throw ManifestError("\(path).id: \"\(widget.id)\" is invalid: use 1–32 lowercase letters, digits, \"_\" or \"-\", starting with a letter or digit")
            }
            guard ids.insert(widget.id).inserted else {
                throw ManifestError("\(path).id: \"\(widget.id)\" is used by another widget")
            }
            guard !widget.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ManifestError("\(path).value: must not be empty")
            }
            guard widget.chart == nil || widget.gauge == nil else {
                throw ManifestError("\(path): a widget shows at most one of \"chart\" and \"gauge\"")
            }
            if let chart = widget.chart {
                let path = "\(path).chart"
                guard (1...3).contains(chart.series.count) else {
                    throw ManifestError("\(path): a chart needs 1–3 series")
                }
                try chart.series.forEach { try requireKey($0.bind, at: path) }
                guard (2...120).contains(chart.points) else {
                    throw ManifestError("\(path): points must be between 2 and 120")
                }
                if let min = chart.min, let max = chart.max {
                    guard min < max else { throw ManifestError("\(path): min must be less than max") }
                }
            }
            if let gauge = widget.gauge {
                try requireKey(gauge.bind, at: "\(path).gauge")
                guard gauge.min < gauge.max else { throw ManifestError("\(path).gauge: min must be less than max") }
            }
            // The detail is laid out like the children of a top-level section.
            try validate(widget.detail, path: "\(path).detail", depth: 2, count: &count)
        }
    }

    private func validateLocalizations() throws {
        guard Self.isValidLanguageCode(language) else {
            throw ManifestError("language: \"\(language)\" is not a language code: use a lowercase BCP 47 language, optionally with a region, such as \"en\" or \"pt-br\"")
        }
        guard localizations.count <= Self.maxLanguages else {
            throw ManifestError("localizations: at most \(Self.maxLanguages) languages")
        }
        for (code, table) in localizations.sorted(by: { $0.key < $1.key }) {
            guard Self.isValidLanguageCode(code) else {
                throw ManifestError("localizations: \"\(code)\" is not a language code: use a lowercase BCP 47 language, optionally with a region, such as \"ru\" or \"pt-br\"")
            }
            guard code != language else {
                throw ManifestError("localizations.\(code): the manifest itself is written in \"\(code)\" (see \"language\"); a table translates it into another language")
            }
            guard table.count <= Self.maxTranslations else {
                throw ManifestError("localizations.\(code): at most \(Self.maxTranslations) entries")
            }
            // A translation can break what the source satisfied, such as the length of the name.
            var translated = localized(for: [code])
            translated.localizations = [:]
            do {
                try translated.validate()
            } catch let error as ManifestError {
                throw ManifestError("localizations.\(code): \(error.message)")
            }
        }
    }
}
