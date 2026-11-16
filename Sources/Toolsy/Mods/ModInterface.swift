import Foundation
import ToolsyEngine
import ToolsyShared

/// The window-free rules of rendering a mod (MOD_FORMAT.md, "Interface"): how bound controls read
/// state, how the page is grouped, what a chart plots and how commands are described to the user.
enum ModInterface {
    // MARK: Bound values

    /// A slider's or stepper's number. Anything but a number in state shows `fallback`.
    static func number(_ value: JSONValue?, fallback: Double) -> Double {
        value?.numberValue ?? fallback
    }

    /// A toggle's position. The bound key holds a boolean; anything else reads as off.
    static func isOn(_ value: JSONValue?) -> Bool {
        value?.boolValue ?? false
    }

    /// An input's text: strings as they are, other scalars in their text form, nothing for the rest.
    static func text(_ value: JSONValue?) -> String {
        guard let value, value.isScalar else { return "" }
        return value.text
    }

    /// The lower bound a stepper starts from when its key holds no number.
    static func stepperFallback(_ stepper: ModControl.Stepper) -> Double {
        min(max(0, stepper.min ?? 0), stepper.max ?? .infinity)
    }

    /// A stepper's range; one-sided when the manifest gives only one bound.
    static func stepperRange(_ stepper: ModControl.Stepper) -> ClosedRange<Double>? {
        guard stepper.min != nil || stepper.max != nil else { return nil }
        return (stepper.min ?? -.infinity)...(stepper.max ?? .infinity)
    }

    /// A picker's options: the manifest's, or with `optionsFrom` those its state key holds right now.
    /// A missing key or one that holds no array gives none.
    static func options(of picker: ModControl.Picker, state: ModState) -> [ModControl.Picker.Option] {
        picker.optionsFrom.map { ModControl.Picker.Option.options(from: state[$0]) } ?? picker.options
    }

    /// The `format` of a gauge or chart, which then formats its readouts instead of the number and `unit`.
    static func valueFormat(_ chain: String?) -> ModValueFormat? {
        // Checked at install and load like templates, so a chain in a loaded manifest always parses.
        chain.flatMap { try? ModValueFormat($0) }
    }

    // MARK: Page layout

    /// A tile of the page: a top-level `section`, or a run of other top-level controls shown as one
    /// untitled group. A top-level `divider` ends a run and is otherwise not drawn.
    enum Block: Equatable, Identifiable {
        case section(Int)
        case group([Int])

        var id: Int {
            switch self {
            case .section(let index): index
            case .group(let indices): indices.first ?? -1
            }
        }
    }

    static func blocks(of ui: [ModControl]) -> [Block] {
        var blocks: [Block] = []
        var run: [Int] = []
        func endRun() {
            if !run.isEmpty { blocks.append(.group(run)) }
            run = []
        }
        for (index, control) in ui.enumerated() {
            switch control.kind {
            case .section:
                endRun()
                blocks.append(.section(index))
            case .divider:
                endRun()
            default:
                run.append(index)
            }
        }
        endRun()
        return blocks
    }

    // MARK: Charts

    /// How many samples span the chart's width. Series bound to arrays plot the whole array, so their
    /// length sets the width; series recorded from numbers keep the manifest's `points`.
    static func chartCapacity(_ chart: ModControl.Chart, state: ModState) -> Int {
        let arrays = chart.series.compactMap { state[$0.bind]?.arrayValue }
        guard arrays.count == chart.series.count else { return chart.points }
        return max(2, arrays.map(\.count).max() ?? 0)
    }

    // MARK: Recent runs

    /// What started a run, in a few words.
    static func text(for event: ModEvent) -> String {
        switch event {
        case .enable: String(localized: "Switched on")
        case .disable: String(localized: "Switched off")
        case .uninstall: String(localized: "Removal")
        case .refresh: String(localized: "Status refresh")
        case .service: String(localized: "Service")
        case .command: String(localized: "A control")
        case .launch: String(localized: "Toolsy started")
        case .wake: String(localized: "Mac woke")
        case .network: String(localized: "Network changed")
        case .power: String(localized: "Power source changed")
        }
    }

    /// How a run ended, in words.
    static func text(for outcome: CommandRun.Outcome) -> String {
        switch outcome {
        case .succeeded: String(localized: "Succeeded")
        case .failed(let code): String(localized: "Failed with code \(Int(code))")
        case .timedOut: String(localized: "Timed out")
        case .couldNotStart(let reason): String(localized: "Couldn’t start: \(reason)")
        case .refused: String(localized: "Refused: no administrator access")
        case .started: String(localized: "Service started")
        case .restarted: String(localized: "Service restarted")
        case .exited(let status): String(localized: "Service exited with code \(Int(status))")
        }
    }

    /// Whether a run is something that went wrong, shown in red with its standard error. A service that
    /// exits with status 0 switches its mod off, as the format intends.
    static func isFailure(_ outcome: CommandRun.Outcome) -> Bool {
        switch outcome {
        case .succeeded, .started, .restarted: false
        case .exited(let status): status != 0
        case .failed, .timedOut, .couldNotStart, .refused: true
        }
    }

    /// How long a run took, or nil for the start of a service, which takes no time worth showing.
    static func durationText(of run: CommandRun) -> String? {
        run.outcome == .started || run.outcome == .restarted ? nil : durationText(run.duration)
    }

    /// Milliseconds under a second, tenths of seconds under a minute, then the two largest units.
    static func durationText(_ duration: Duration, locale: Locale = .autoupdatingCurrent) -> String {
        if duration < .seconds(1) {
            return duration.formatted(.units(allowed: [.milliseconds], width: .abbreviated).locale(locale))
        }
        if duration < .seconds(60) {
            return duration.formatted(.units(allowed: [.seconds], width: .abbreviated, fractionalPart: .show(length: 1)).locale(locale))
        }
        return duration.formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2).locale(locale))
    }

    // MARK: Commands

    /// Whether `command` must run as root. Unknown names are not: the engine reports them itself.
    static func isPrivileged(_ command: String?, in manifest: ModManifest) -> Bool {
        guard let command else { return false }
        return manifest.commands[command]?.privileged == true
    }

    /// One line per privileged command, `name: program arguments`, for the dialogs that ask the
    /// user to let a mod run as administrator.
    static func privilegedCommandLines(of manifest: ModManifest) -> [String] {
        manifest.commands.filter(\.value.privileged).keys.sorted().compactMap { name in
            guard let command = manifest.commands[name] else { return nil }
            let program: String
            switch command.program {
            case .exec(let path): program = ([path] + command.args).joined(separator: " ")
            case .shell(let script): program = "sh -c " + script.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let line = "\(name): \(program)"
            return line.count > 120 ? String(line.prefix(119)) + "…" : line
        }
    }

    // MARK: Messages

    /// The user-facing sentence for a failure of the administrator helper.
    static func message(for error: PrivilegedError, modName: String) -> String {
        switch error {
        case .helperUnavailable(.needsUpdate):
            String(localized: "Toolsy’s administrator helper needs to be updated.")
        case .helperUnavailable:
            String(localized: "Toolsy’s administrator helper is not installed.")
        case .cancelled:
            String(localized: "Administrator access was not granted.")
        case .notApproved:
            String(localized: "“\(modName)” is not allowed to run commands as administrator.")
        case .busy:
            String(localized: "A command is still running as administrator. Try again when it has finished.")
        case .rejected(let reason):
            String(localized: "The administrator helper refused the request: \(reason)")
        case .connection(let reason):
            String(localized: "Toolsy could not reach its administrator helper: \(reason)")
        }
    }

    /// The sentence for any error thrown by the store: helper failures in the user's language, the
    /// engine's own messages (which name the offending field of a manifest) as they are.
    static func message(for error: any Error, modName: String) -> String {
        if let failure = error as? PrivilegedError { return message(for: failure, modName: modName) }
        return error.localizedDescription
    }

    /// A mod's `error` in the user's language when the engine wrote it from a `PrivilegedError`; any
    /// other message (the mod's own, a command's output) is shown as written.
    static func displayedError(_ message: String, of mod: ModManifest) -> String {
        let known: [PrivilegedError] = [
            .helperUnavailable(.needsUpdate), .helperUnavailable(.notInstalled), .cancelled, .busy,
            .notApproved(modID: mod.id),
        ]
        if let error = known.first(where: { $0.localizedDescription == message }) {
            return Self.message(for: error, modName: mod.name)
        }
        let unreachable = PrivilegedError.connection("").localizedDescription
        if message.hasPrefix(unreachable) {
            return Self.message(for: .connection(String(message.dropFirst(unreachable.count))), modName: mod.name)
        }
        return message
    }

    /// What the install confirmation adds about the administrator password, or nil when the helper is ready.
    static func passwordNotice(for status: HelperStatus) -> String? {
        switch status {
        case .needsUpdate:
            String(localized: "Toolsy was updated, so macOS will ask for your administrator password once to update its helper.")
        case .notInstalled:
            String(localized: "macOS will ask for your administrator password once to install Toolsy’s helper. It won’t ask again after that.")
        case .ready:
            nil
        }
    }

    /// What is wrong when a privileged command cannot run, and the one action that fixes it.
    enum AccessRemedy: Equatable {
        /// The helper must be updated (Toolsy was updated); the mod keeps its approval.
        case updateHelper
        /// The mod has no approval on this Mac: install it again from its package.
        case reinstall
        /// The installed files differ from the approved ones: a warning, and installing again.
        case reinstallModified
    }

    static func remedy(for access: AdministratorAccess) -> AccessRemedy? {
        switch access {
        case .notNeeded, .granted: nil
        case .helperUnavailable(.needsUpdate): .updateHelper
        case .helperUnavailable, .notApproved(modified: false): .reinstall
        case .notApproved(modified: true): .reinstallModified
        }
    }

    /// Title and explanation of a missing access, for the mod page banner and the dialog shown when the
    /// user starts something that needs it.
    static func explanation(of remedy: AccessRemedy, modName name: String) -> (title: String, message: String) {
        switch remedy {
        case .updateHelper:
            (String(localized: "Toolsy’s helper needs an update"),
             String(localized: "Toolsy was updated, so its administrator helper has to be updated once before “\(name)” can run its administrator commands. macOS will ask for your password. The mod keeps its access."))
        case .reinstall:
            (String(localized: "“\(name)” has no administrator access"),
             String(localized: "“\(name)” has no administrator access on this Mac, for example because Toolsy’s helper was removed. To run its administrator commands, install it again from its .toolsymod file. Its settings are kept."))
        case .reinstallModified:
            (String(localized: "The files of “\(name)” were changed"),
             String(localized: "The files of “\(name)” were changed after it was installed, so its administrator commands are blocked. If you didn’t change them, remove the mod. To use it, install it again from its .toolsymod file."))
        }
    }
}
