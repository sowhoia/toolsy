import Foundation
import ToolsyEngine
import ToolsyShared

/// What `run` prints: one run and everything Toolsy would make of it. `--json` encodes it as is; `text` is
/// the same for a person.
struct RunReport: Encodable {
    /// Standard output of a command, or one line of a service, as Toolsy reads it.
    struct Output: Encodable {
        /// `patch`, `capture`, `empty`, `notAnObject` or `notJSON`.
        let kind: String
        /// What is merged into the state: the patch, or `{capture key: text}`.
        let patch: ModState?
        /// The output that is not JSON.
        let text: String?
        /// The JSON value that is not an object.
        let value: JSONValue?
        /// Why the output is not JSON, in the parser's words.
        let reason: String?
        /// Keys of the patch Toolsy itself reads (`enabled`, `status`, `level`, `error`), sorted.
        let hostKeys: [String]
        /// The notification the patch's `notify` shows.
        let notification: Notification?
    }

    struct Notification: Encodable {
        let title: String
        let body: String
    }

    /// The run succeeded: exit status 0 within the timeout, or a service still running when it was stopped.
    let ok: Bool
    let mod: String
    let command: String
    /// `exec <file> <args>` or `shell <script>`.
    let program: String
    let event: String
    /// `TOOLSY_LOCALE` as the command saw it.
    let locale: String?
    let key: String?
    let value: JSONValue?
    /// What the command read on standard input, when it asks for it.
    let stdin: CommandInput?
    let dataDirectory: String
    let dataDirectoryRemoved: Bool
    /// Nil when the program could not be started.
    let exitStatus: Int32?
    let timedOut: Bool
    /// Seconds the command was allowed: its timeout, or for the service how long it ran before being stopped.
    let timeout: Double
    let seconds: Double
    let service: Bool
    /// The output of a one-shot command.
    let output: Output?
    /// Each line a service printed, in order.
    let lines: [Output]?
    /// The `error` Toolsy shows for this run, when it failed.
    let error: String?
    let notes: [String]
    let stderr: String

    init(manifest: ModManifest, command: ModCommand, name: String, input: CommandInput, environment: [String: String],
         dataDirectory: URL, temporary: Bool, isService: Bool, timeout: Double, seconds: Double,
         outcome: Result<CommandResult, any Error>, notes: [String]) {
        mod = manifest.id
        self.command = name
        program = switch command.program {
        case .exec(let file): (["exec", file] + command.args).joined(separator: " ")
        case .shell(let script): "shell \(JSONValue.string(script).compactJSON)" + (command.args.isEmpty ? "" : " " + command.args.joined(separator: " "))
        }
        event = input.event.rawValue
        locale = environment["TOOLSY_LOCALE"]
        key = input.key
        value = input.value
        stdin = command.stdin ? input : nil
        self.dataDirectory = dataDirectory.path(percentEncoded: false)
        dataDirectoryRemoved = temporary
        self.timeout = timeout
        self.seconds = (seconds * 100).rounded() / 100
        service = isService
        var notes = notes
        let result: CommandResult
        switch outcome {
        case .failure(let failure):
            (ok, exitStatus, timedOut, output, lines, stderr) = (false, nil, false, nil, nil, "")
            error = failure.localizedDescription
            self.notes = notes
            return
        case .success(let success):
            result = success
        }
        exitStatus = result.exitCode
        timedOut = result.timedOut
        stderr = String(decoding: result.stderr, as: UTF8.self)
        // Toolsy names notifications after the mod in the user's language.
        let modName = manifest.localized(for: [input.locale].compactMap(\.self)).name
        if isService {
            // Stopped by the tool after `--for` seconds is how a healthy service ends here.
            ok = result.timedOut || result.exitCode == 0
            output = nil
            // Blank lines change nothing and are not counted.
            let printed = result.stdout.split(separator: UInt8(ascii: "\n")).map { Data($0) }.filter { CommandOutput($0) != .empty }
            lines = printed.enumerated().map { index, line in
                Self.read(line, of: command, manifest: manifest, modName: modName, isService: true, applied: true) { note in
                    notes.append("line \(index + 1): \(note)")
                }
            }
            if result.timedOut {
                error = nil
            } else if result.exitCode == 0 {
                error = nil
                notes.append("the service ended with exit status 0: Toolsy switches the mod off, as if the user had (running disable)")
            } else {
                error = result.serviceFailureMessage
                notes.append("Toolsy restarts a failed service after 1, 2, 4 … up to 60 seconds and shows the error meanwhile")
            }
        } else {
            ok = result.succeeded
            lines = nil
            output = Self.read(result.stdout, of: command, manifest: manifest, modName: modName, isService: false, applied: ok) { notes.append($0) }
            if ok {
                error = nil
            } else {
                error = result.failureMessage(command: name, timeout: command.timeout)
                notes.append("the command failed, so Toolsy discards its output (a patch and its notify included) and keeps the state as it was")
            }
        }
        self.notes = notes
    }

    /// Classifies output the way `Mod` reads it. When it is `applied` (the run succeeded), also notes what Toolsy
    /// ignores or does with the patch and which notification it shows.
    private static func read(_ data: Data, of command: ModCommand, manifest: ModManifest, modName: String, isService: Bool,
                             applied: Bool, note: (String) -> Void) -> Output {
        guard applied else {
            return read(data, of: command, manifest: manifest, modName: modName, isService: isService, applied: true) { _ in }.discarded
        }
        if let capture = command.capture {
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return Output(kind: "capture", patch: [capture: .string(text)], text: nil, value: nil, reason: nil,
                          hostKeys: ReservedStateKey.all.contains(capture) ? [capture] : [], notification: nil)
        }
        switch CommandOutput(data) {
        case .empty:
            return Output(kind: "empty", patch: nil, text: nil, value: nil, reason: nil, hostKeys: [], notification: nil)
        case .notAnObject(let value):
            note("the output is JSON but not an object, so Toolsy ignores it; a patch is one object such as {\"status\": \"Ready\"}")
            return Output(kind: "notAnObject", patch: nil, text: nil, value: value, reason: nil, hostKeys: [], notification: nil)
        case .notJSON(let reason):
            note("the output is not JSON, so Toolsy ignores it; print one JSON object, or set \"capture\" to keep text")
            return Output(kind: "notJSON", patch: nil, text: String(decoding: data, as: UTF8.self), value: nil, reason: reason,
                          hostKeys: [], notification: nil)
        case .patch(let patch):
            var notification: Notification?
            for key in patch.keys.sorted() {
                let value = patch[key] ?? .null
                if !ModManifest.isValidKey(key) {
                    note("\"\(key)\" is not a valid state key ([A-Za-z_][A-Za-z0-9_]*, up to 64), so Toolsy ignores it")
                    continue
                }
                switch key {
                case ReservedStateKey.notify:
                    if let shown = ModNotification(value, modID: manifest.id, modName: modName) {
                        notification = Notification(title: shown.title, body: shown.body)
                    } else if value.stringValue != nil || value.objectValue != nil {
                        note("notify has no text to show, so no notification appears")
                    } else if value != .null {
                        note("notify must be text or an object with \"title\" and \"body\", so Toolsy ignores \(value.compactJSON)")
                    }
                case ReservedStateKey.enabled where value.boolValue == nil:
                    note("enabled must be true or false, so Toolsy ignores \(value.compactJSON)")
                case ReservedStateKey.status where value.stringValue == nil && value != .null:
                    note("status is shown only when it is text; \(value.compactJSON) shows no status")
                case ReservedStateKey.level where value != .null && value.stringValue.flatMap(ModLevel.init(rawValue:)) == nil:
                    note("level is one of \"ok\", \"warn\", \"error\" and \"off\"; \(value.compactJSON) colours nothing")
                case _ where manifest.settings[key] != nil:
                    let restart = !isService && manifest.lifecycle.service != nil ? " and restarts the service" : ""
                    note("\"\(key)\" is a setting: Toolsy saves its new value\(restart)")
                default:
                    break
                }
            }
            let hostKeys = patch.keys.filter { key in
                key == ReservedStateKey.enabled ? patch[key]?.boolValue != nil : ReservedStateKey.all.contains(key) && key != ReservedStateKey.notify
            }.sorted()
            return Output(kind: "patch", patch: patch, text: nil, value: nil, reason: nil, hostKeys: hostKeys, notification: notification)
        }
    }

    // MARK: - Text

    var text: String {
        var lines: [String] = []
        func add(_ label: String, _ text: String) {
            let rows = text.split(separator: "\n", omittingEmptySubsequences: false)
            lines.append(label.padding(toLength: 9, withPad: " ", startingAt: 0) + (rows.first ?? ""))
            lines += rows.dropFirst().map { String(repeating: " ", count: 9) + $0 }
        }
        /// The keys of a patch Toolsy reads itself, and its notification.
        func addEffects(of output: Output) {
            for key in output.hostKeys {
                let value = output.patch?[key] ?? .null
                add("toolsy:", "\(key) = \(value.compactJSON): \(Self.meaning(of: key, value))")
            }
            if let notification = output.notification {
                add("notify:", "title \(JSONValue.string(notification.title).compactJSON), body \(JSONValue.string(notification.body).compactJSON)")
            }
        }
        add("command:", "\(command) of \(mod): \(program)")
        add("event:", event)
        add("locale:", locale ?? "none (TOOLSY_LOCALE is not set)")
        if let key { add("key:", key) }
        if let value { add("value:", value.compactJSON) }
        if let stdin { add("stdin:", stdin.compactJSON) }
        add("data:", dataDirectory + (dataDirectoryRemoved ? " (temporary, removed after the run; --data keeps one)" : ""))
        add("result:", resultSentence)
        if let error {
            add("error:", "Toolsy shows \(JSONValue.string(error).compactJSON)")
        }
        if let output {
            add("output:", describe(output))
            addEffects(of: output)
        }
        if let outputLines = self.lines {
            add("output:", outputLines.isEmpty ? "no lines" : "\(outputLines.count) line\(outputLines.count == 1 ? "" : "s"), each applied at once:")
            for (index, line) in outputLines.enumerated() {
                let shown = line.patch.map { JSONValue.object($0).compactJSON } ?? line.text ?? line.value?.compactJSON ?? ""
                add("", "line \(index + 1): \(describe(line)) \(shown)")
            }
            // Every line has the same meaning; each key Toolsy reads is explained once, each notification shown.
            for key in Set(outputLines.flatMap(\.hostKeys)).sorted() {
                add("toolsy:", "\(key): \(Self.meaning(of: key, nil))")
            }
            for (index, line) in outputLines.enumerated() {
                if let notification = line.notification {
                    add("notify:", "line \(index + 1): title \(JSONValue.string(notification.title).compactJSON), body \(JSONValue.string(notification.body).compactJSON)")
                }
            }
        }
        notes.forEach { add("note:", $0) }
        add("stderr:", stderr.isEmpty ? "(empty)" : stderr.hasSuffix("\n") ? String(stderr.dropLast()) : stderr)
        return lines.joined(separator: "\n")
    }

    private var resultSentence: String {
        let duration = "after \(JSONValue.number(seconds).text) s"
        guard let exitStatus else { return "FAILED: could not start the program" }
        if service {
            if timedOut { return "still running \(duration), then stopped as Toolsy stops a service (SIGTERM to its process group)" }
            return exitStatus == 0 ? "the service ended by itself with exit status 0 \(duration)" : "FAILED: the service ended with exit status \(exitStatus) \(duration)"
        }
        if timedOut { return "FAILED: timed out \(duration), its timeout of \(JSONValue.number(timeout).text) s, and was killed" }
        return exitStatus == 0 ? "exit status 0 \(duration)" : "FAILED: exit status \(exitStatus) \(duration)"
    }

    private func describe(_ output: Output) -> String {
        switch output.kind {
        case "patch": service ? "a patch" : "a patch, merged into the mod's state:\n" + JSONValue.object(output.patch ?? [:]).prettyJSON
        case "capture": "captured as text into \"\(output.patch?.keys.first ?? "")\": \((output.patch?.values.first ?? .null).compactJSON)"
        case "notAnObject": service ? "ignored, JSON but not an object:" : "ignored, JSON but not an object: \(output.value?.compactJSON ?? "")"
        case "notJSON": service ? "ignored, not JSON (\(output.reason ?? "")):" : "ignored, not JSON (\(output.reason ?? "")):\n" + (output.text ?? "")
        default: "empty, which changes nothing"
        }
    }

    /// What Toolsy does with a key it reads itself; for `value` nil, in general.
    private static func meaning(of key: String, _ value: JSONValue?) -> String {
        switch key {
        case ReservedStateKey.status: "the line under the mod's name"
        case ReservedStateKey.level: "the colour of that line"
        case ReservedStateKey.error:
            switch value {
            case nil: "text is shown as the mod's error, anything else clears it"
            case let value?: value.stringValue?.isEmpty == false ? "shown as the mod's error" : "clears the mod's error"
            }
        default: "moves the switch without running enable or disable; the service starts or stops to match"
        }
    }
}

extension RunReport.Output {
    /// The same output of a failed run: Toolsy applies none of it.
    var discarded: Self {
        Self(kind: kind, patch: patch, text: text, value: value, reason: reason, hostKeys: [], notification: nil)
    }
}

extension Encodable {
    /// One line of JSON with sorted keys.
    var compactJSON: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // Values here came from JSON or are plain strings, so they always encode.
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    var prettyJSON: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
}
