import Foundation

extension ModManifest {
    static let maxControls = 200
    static let maxNesting = 4

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
            // A captured string under `enabled` would be truthy even for the text "false".
            guard Self.isValidKey(capture), capture != ReservedStateKey.enabled else {
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

    private func requireKey(_ key: String, at path: String) throws {
        guard Self.isValidKey(key) else {
            throw ManifestError("\(path): bind \"\(key)\" is not a valid key")
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
                throw ManifestError("ui: more than \(Self.maxControls) controls")
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
            guard (1...32).contains(picker.options.count) else {
                throw ManifestError("\(path): a picker needs 1–32 options")
            }
            guard picker.options.allSatisfy(\.value.isScalar) else {
                throw ManifestError("\(path): option values must be strings, numbers or booleans")
            }
        case .input(let input):
            try requireEditableKey(input.bind, at: path)
            try command(input.command)
        case .button(let button):
            try command(button.command)
            guard (button.command == nil) != (button.open == nil) else {
                throw ManifestError("\(path): a button needs exactly one of \"command\" and \"open\"")
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
            for series in chart.series {
                try requireKey(series.bind, at: path)
            }
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
        case .value, .text, .divider:
            break
        }
    }
}
