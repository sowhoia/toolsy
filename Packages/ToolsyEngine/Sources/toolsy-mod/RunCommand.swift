import Foundation
import ToolsyEngine
import ToolsyShared

/// `run`: one command of a mod folder, started as Toolsy starts it, and a report of what Toolsy would make
/// of the outcome. A privileged command never runs as root here; the helper is never contacted.
struct RunCommand {
    static let options: Set<String> = ["--state", "--key", "--value", "--event", "--locale", "--data", "--for"]
    /// How long a service runs when `--for` is not given.
    static let defaultServiceSeconds: Double = 5

    let folder: URL
    let name: String
    /// `--state`, merged over the starting state.
    let stateChanges: ModState
    let key: String?
    let value: JSONValue?
    let event: ModEvent?
    let locale: String?
    let dataDirectory: URL?
    let serviceSeconds: Double?
    let asUser: Bool
    let json: Bool

    init(_ arguments: Arguments) throws(UsageError) {
        func fail(_ message: String) -> UsageError { UsageError(message: message, command: "run") }
        let positionals = try arguments.positionals(2...2, "a mod folder and the name of one of its commands")
        folder = absolute(positionals[0])
        name = positionals[1]
        let state = try arguments.json("--state") ?? [:]
        guard let stateChanges = state.objectValue else { throw fail("--state must be a JSON object") }
        self.stateChanges = stateChanges
        for (key, value) in stateChanges {
            guard ModManifest.isValidKey(key) else { throw fail("--state: \"\(key)\" is not a valid state key") }
            guard key != ReservedStateKey.notify else { throw fail("--state: notify is never part of the state") }
            guard key != ReservedStateKey.enabled || value.boolValue != nil || value == .null else {
                throw fail("--state: enabled must be true or false")
            }
        }
        key = arguments.value("--key")
        value = try arguments.json("--value")
        if let key, !ModManifest.isValidKey(key) {
            throw fail("--key: \"\(key)\" is not a valid state key")
        }
        guard key == nil || value != nil else {
            throw fail("--key needs --value: a control always sends its value with its key")
        }
        if let name = arguments.value("--event") {
            guard let event = ModEvent(rawValue: name) else {
                throw fail("--event: \"\(name)\" is not one of enable, disable, uninstall, refresh, service, command, launch, wake, network, power")
            }
            self.event = event
        } else {
            event = nil
        }
        // The check CommandEnvironment applies before it passes a locale on.
        if let locale = arguments.value("--locale"), locale.wholeMatch(of: /[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})*/) == nil {
            throw fail("--locale: \"\(locale)\" is not a BCP 47 language code such as ru or en-us")
        }
        locale = arguments.value("--locale")
        dataDirectory = arguments.value("--data").map { absolute($0) }
        if let text = arguments.value("--for") {
            guard let seconds = Double(text), seconds > 0, seconds <= ModCommand.maxTimeout else {
                throw fail("--for: \"\(text)\" is not a number of seconds between 0 and \(Int(ModCommand.maxTimeout))")
            }
            serviceSeconds = seconds
        } else {
            serviceSeconds = nil
        }
        asUser = arguments.has("--as-user")
        json = arguments.has("--json")
    }

    func run() async throws -> Int32 {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path(percentEncoded: false), isDirectory: &isFolder), isFolder.boolValue else {
            throw UsageError(message: "\(folder.path(percentEncoded: false)) is not a folder: run takes an unpacked mod", command: "run")
        }
        let manifest = try await ModPackage.validate(folder)
        guard let command = manifest.commands[name] else {
            let known = manifest.commands.keys.sorted().joined(separator: ", ")
            throw UsageError(message: "\(manifest.id) has no command \"\(name)\"; its commands: \(known.isEmpty ? "none" : known)", command: "run")
        }
        let isService = manifest.lifecycle.service == name
        if serviceSeconds != nil, !isService {
            throw UsageError(message: "--for applies to the service only; \"\(name)\" runs to its end or its timeout", command: "run")
        }
        if command.privileged, !asUser {
            throw UsageError(message: "\"\(name)\" is privileged: Toolsy runs it as root through its helper, and toolsy-mod never does. Add --as-user to run it as yourself (with root's environment) and test what needs no root, such as a status check or the validation of its input.", command: "run")
        }
        if asUser, !command.privileged {
            throw UsageError(message: "--as-user is for privileged commands; \"\(name)\" runs as the user anyway", command: "run")
        }

        var input = CommandInput(event: event ?? (isService ? .service : .command), command: name, key: key, value: value,
                                 state: startingState(of: manifest),
                                 locale: locale ?? manifest.shownLanguage(for: Locale.preferredLanguages))
        var notes: [String] = []
        if command.privileged {
            notes.append("\"\(name)\" is privileged: it ran as \(NSUserName()), not root, with root's environment (PATH of system directories only); whatever needs root failed or did something else")
        }
        if let key, let value, Self.inputBinds(key, in: manifest) {
            // What `Mod.setValue` does before it runs a bound control's command.
            input.state[key] = value == .null ? JSONValue?.none : value
            notes.append("an input binds \"\(key)\", so its value was stored in the state first, as the control does")
        }

        let data: URL, temporary: URL?
        if let dataDirectory {
            (data, temporary) = (dataDirectory, nil)
        } else {
            let scratch = FileManager.default.temporaryDirectory.appending(path: "toolsy-mod-run-\(UUID().uuidString)", directoryHint: .isDirectory)
            (data, temporary) = (scratch.appending(path: manifest.id, directoryHint: .isDirectory), scratch)
        }
        defer {
            // A failure leaves only clutter in the temporary folder.
            if let temporary { try? FileManager.default.removeItem(at: temporary) }
        }
        var request = try command.request(modID: manifest.id, modDirectory: folder, dataDirectory: data, input: input,
                                          privileged: command.privileged)
        if isService {
            // Toolsy applies no timeout to the service; the tool stops it like Toolsy stops one.
            request.timeout = serviceSeconds ?? Self.defaultServiceSeconds
        }
        let started = ContinuousClock.now
        let outcome: Result<CommandResult, any Error>
        do {
            outcome = .success(try await ProcessRunner.run(request))
        } catch {
            outcome = .failure(error)
        }
        let report = RunReport(
            manifest: manifest, command: command, name: name, input: input, environment: request.environment,
            dataDirectory: data, temporary: temporary != nil, isService: isService, timeout: request.timeout,
            seconds: started.duration(to: .now) / .seconds(1), outcome: outcome, notes: notes
        )
        if json {
            try printJSON(report)
        } else {
            print(report.text)
        }
        return report.ok ? 0 : 1
    }

    /// The settings with their defaults and the switch off, as a mod starts, with `--state` merged over it.
    func startingState(of manifest: ModManifest) -> ModState {
        var state = manifest.settings
        state[ReservedStateKey.enabled] = false
        for (key, value) in stateChanges {
            state[key] = value == .null ? JSONValue?.none : value
        }
        return state
    }

    /// Whether a control the user edits writes `key`: those store their value before their command runs.
    static func inputBinds(_ key: String, in manifest: ModManifest) -> Bool {
        manifest.allControls.contains { control in
            switch control.kind {
            case .toggle(let toggle): toggle.bind == key
            case .slider(let slider): slider.bind == key
            case .stepper(let stepper): stepper.bind == key
            case .picker(let picker): picker.bind == key
            case .input(let input): input.bind == key
            default: false
            }
        }
    }
}
