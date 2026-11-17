import Foundation
import ToolsyShared

extension ModPackage {
    /// Runs every check `validate` runs and also returns the package's warnings: things that are valid but
    /// almost always a mistake, each a sentence that starts with the path of what it is about. Sorted.
    public static func inspect(_ package: URL) async throws -> (manifest: ModManifest, warnings: [String], signature: ModSignature?) {
        let scratch = try temporaryDirectory(appropriateFor: nil)
        defer { remove(scratch) }
        let (manifest, payload, signature) = try await read(package, scratch: scratch)
        return (manifest, manifest.warnings(files: payload), signature)
    }
}

extension ModManifest {
    /// Each warning is precise: it fires only when Toolsy will certainly behave in a way the author did not
    /// intend, never on a guess about what commands report.
    func warnings(files payload: ModPayload) -> [String] {
        programsShellCannotStart(in: payload) + unsuitableSettingDefaults() + unusedTranslations()
    }

    /// Every control of the page and of the widgets' details with its path, depth first.
    private var locatedControls: [(path: String, control: ModControl)] {
        func walk(_ controls: [ModControl], _ path: String) -> [(path: String, control: ModControl)] {
            controls.enumerated().flatMap { index, control in
                [("\(path)[\(index)]", control)] + walk(control.children, "\(path)[\(index)].children")
            }
        }
        return walk(ui, "ui") + widgets.enumerated().flatMap { index, widget in walk(widget.detail, "widgets[\(index)].detail") }
    }

    /// A `shell` script that starts with a path inside the mod (`scripts/run.sh …`, `./run.sh`) fails unless
    /// that file is part of the mod and executable.
    private func programsShellCannotStart(in payload: ModPayload) -> [String] {
        commands.sorted(by: { $0.key < $1.key }).compactMap { name, command in
            guard case .shell(let script) = command.program,
                  let word = script.split(whereSeparator: \.isWhitespace).first,
                  word.wholeMatch(of: /(?:\.\/)?[A-Za-z0-9._-]+(?:\/[A-Za-z0-9._-]+)*/) != nil, word.contains("/")
            else { return nil }
            let file = word.hasPrefix("./") ? String(word.dropFirst(2)) : String(word)
            if payload.files[file] == nil {
                return "commands.\(name): shell starts with \"\(word)\", which is not a file of the mod"
            }
            if !payload.executables.contains(file) {
                return "commands.\(name): shell starts with \"\(word)\", which is not executable (chmod +x)"
            }
            return nil
        }
    }

    /// An input bound to a setting whose default it cannot show: a toggle shows a non-boolean as off, a picker
    /// selects nothing for a value none of its options has (`"1"` is not `1`), a slider or stepper shows its
    /// minimum for a non-number and clamps a number outside its range, a text field is empty for an array.
    private func unsuitableSettingDefaults() -> [String] {
        locatedControls.compactMap { path, control in
            let problem: (key: String, issue: String)? = switch control.kind {
            case .toggle(let toggle):
                settings[toggle.bind].flatMap { $0.boolValue == nil ? (toggle.bind, "is not true or false; the toggle shows it as off") : nil }
            case .slider(let slider):
                settings[slider.bind].flatMap { Self.numberIssue($0, min: slider.min, max: slider.max, control: "slider") }.map { (slider.bind, $0) }
            case .stepper(let stepper):
                settings[stepper.bind].flatMap { Self.numberIssue($0, min: stepper.min, max: stepper.max, control: "stepper") }.map { (stepper.bind, $0) }
            case .picker(let picker) where picker.optionsFrom == nil:
                settings[picker.bind].flatMap { value in
                    picker.options.contains { $0.value == value } ? nil : (picker.bind, "matches the value of none of the options (\(picker.options.map(\.value.json).joined(separator: ", "))); the picker shows nothing selected")
                }
            case .input(let input):
                settings[input.bind].flatMap { $0.isScalar ? nil : (input.bind, "is not text, a number or a boolean; the field shows nothing") }
            default:
                nil
            }
            guard let problem, let value = settings[problem.key] else { return nil }
            return "\(path): the default of setting \"\(problem.key)\", \(value.json), \(problem.issue)"
        }
    }

    private static func numberIssue(_ value: JSONValue, min: Double?, max: Double?, control: String) -> String? {
        guard let number = value.numberValue else { return "is not a number; the \(control) shows its minimum" }
        if let min, number < min { return "is below the \(control)'s min \(JSONValue.number(min).text)" }
        if let max, number > max { return "is above the \(control)'s max \(JSONValue.number(max).text)" }
        return nil
    }

    /// A translation whose source text appears in no translated field is never shown: usually the source was
    /// edited, or misspelt, after it was translated. Checked with `localized(for:)` itself, so it agrees with
    /// what Toolsy translates.
    private func unusedTranslations() -> [String] {
        localizations.keys.sorted().flatMap { code in
            (localizations[code] ?? [:]).keys.sorted().compactMap { source in
                var probe = self
                // A translation that differs from every source text, so any use of it changes the manifest.
                probe.localizations = [code: [source: source + "\u{0}"]]
                guard probe.localized(for: [code]) == probe else { return nil }
                return "localizations.\(code): \(JSONValue.string(source).json) is not the text of any translated field, so this entry is never used"
            }
        }
    }
}

extension JSONValue {
    /// Compact JSON with sorted keys, for messages: strings are quoted, unlike `text`.
    var json: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // A JSONValue always encodes; numbers are finite because they came from JSON.
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? text
    }
}
