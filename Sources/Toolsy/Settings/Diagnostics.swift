import Foundation
import SwiftUI
import ToolsyEngine
import ToolsyShared

/// A plain-text report to paste into a bug report: what Toolsy and the Mac are, and what the mods are and did. It
/// never holds a mod's settings, state, standard output or standard error, which can carry the user's data, and it
/// writes the home folder as "~". In English whatever the app's language, for whoever reads the bug report.
enum Diagnostics {
    struct Facts: Equatable {
        var toolsyVersion: String
        var build: String?
        /// "macOS 26.1 (25B78)".
        var system: String
        var model: String
        var chip: String
        var architecture: String
        var helper: HelperStatus
        var developerMode: Bool
        var mods: [ModFacts]
        var loadProblems: [LoadProblemFacts]
        var widgets: [String]
    }

    struct ModFacts: Equatable {
        var id: String
        var version: String
        /// Nil for a mod without a switch.
        var isOn: Bool?
        /// `.notNeeded` for a mod without administrator commands.
        var access: AdministratorAccess
        /// Oldest first.
        var runs: [RunFacts]
    }

    /// What `CommandRun` holds but its standard error.
    struct RunFacts: Equatable {
        var command: String
        var cause: ModEvent
        var duration: Duration
        var outcome: CommandRun.Outcome
    }

    struct LoadProblemFacts: Equatable {
        var folder: String
        var message: String
    }

    static func report(_ facts: Facts, home: String) -> String {
        var lines = [
            "Toolsy \(facts.toolsyVersion)" + (facts.build.map { " (\($0))" } ?? ""),
            facts.system,
            "\(facts.model), \(facts.chip), \(facts.architecture)",
            "Administrator helper: \(text(for: facts.helper))",
            "Developer mode: \(facts.developerMode ? "on" : "off")",
            "",
            "Mods: \(facts.mods.count)",
        ]
        for mod in facts.mods {
            let state = mod.isOn.map { $0 ? "on" : "off" } ?? "no switch"
            lines.append("\(mod.id) \(mod.version): \(state), \(text(for: mod.access))")
            lines += mod.runs.isEmpty ? ["  no runs"] : mod.runs.map { "  " + text(for: $0) }
        }
        if !facts.loadProblems.isEmpty {
            lines += ["", "Mods that could not be loaded: \(facts.loadProblems.count)"]
            lines += facts.loadProblems.map { "\($0.folder): \($0.message)" }
        }
        lines += ["", "Dashboard: " + (facts.widgets.isEmpty ? "no widgets" : facts.widgets.joined(separator: ", "))]
        let report = lines.joined(separator: "\n") + "\n"
        // Paths in messages would otherwise name the user's account.
        return home.count > 1 ? report.replacingOccurrences(of: home, with: "~") : report
    }

    private static func text(for status: HelperStatus) -> String {
        switch status {
        case .notInstalled: "not installed"
        case .needsUpdate: "needs update"
        case .ready: "ready"
        }
    }

    private static func text(for access: AdministratorAccess) -> String {
        switch access {
        case .notNeeded: "no administrator commands"
        case .granted: "administrator commands, allowed"
        case .helperUnavailable(let status): "administrator commands, helper \(text(for: status))"
        case .notApproved(let modified):
            modified ? "administrator commands, files changed since installing" : "administrator commands, not allowed"
        }
    }

    /// "status on refresh: succeeded, 45 ms": the command, what started it (the format's own word), how it ended
    /// and how long it took.
    private static func text(for run: RunFacts) -> String {
        let outcome: String = switch run.outcome {
        case .succeeded: "succeeded"
        case .failed(let code): "failed with code \(code)"
        case .timedOut: "timed out"
        case .couldNotStart(let reason): "could not start: \(reason)"
        case .refused: "refused: no administrator access"
        case .started: "service started"
        case .restarted: "service restarted"
        case .exited(let status): "service exited with code \(status)"
        }
        // The start of a service takes no time worth reporting.
        let duration = run.outcome == .started || run.outcome == .restarted
            ? "" : ", " + ModInterface.durationText(run.duration, locale: Locale(identifier: "en_US_POSIX"))
        return "\(run.command) on \(run.cause.rawValue): \(outcome)\(duration)"
    }

    /// What the report says now.
    static func facts(mods model: ModsModel, dashboard: DashboardStore) -> Facts {
        let info = Bundle.main.infoDictionary
        let device = DeviceInfo.current()
        return Facts(
            toolsyVersion: info?["CFBundleShortVersionString"] as? String ?? ToolsyVersion.current,
            build: info?["CFBundleVersion"] as? String,
            system: device.system,
            model: device.model,
            chip: device.chip,
            architecture: architecture,
            helper: model.store.helperStatus,
            developerMode: model.developerMode,
            mods: model.store.mods.map { mod in
                ModFacts(id: mod.id, version: mod.manifest.version, isOn: mod.hasSwitch ? mod.isEnabled : nil, access: mod.access,
                         runs: mod.recentRuns.map { RunFacts(command: $0.command, cause: $0.event, duration: $0.duration, outcome: $0.outcome) })
            },
            loadProblems: model.store.loadProblems.map { LoadProblemFacts(folder: $0.folder, message: $0.message) },
            widgets: dashboard.layout.widgets.map(\.id.rawValue)
        )
    }

    /// The architecture Toolsy runs as.
    private static var architecture: String {
        #if arch(arm64)
        "arm64"
        #else
        Sysctl.value("sysctl.proc_translated", as: Int32.self) == 1 ? "x86_64 under Rosetta" : "x86_64"
        #endif
    }
}

/// Settings' row that copies the diagnostics report, and says so for a moment.
struct CopyDiagnosticsRow: View {
    @Environment(ModsModel.self) private var model
    @Environment(DashboardStore.self) private var dashboard
    @State private var copied = CopyFeedback()

    var body: some View {
        Button {
            copied.copy(Diagnostics.report(Diagnostics.facts(mods: model, dashboard: dashboard), home: NSHomeDirectory()))
        } label: {
            HStack(spacing: 10) {
                IconBadge("stethoscope", tint: .gray, size: 24)
                Text("Copy Diagnostics")
                    .font(.rowLabel)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if copied.isShowing {
                    Label(String(localized: "Copied"), systemImage: "checkmark")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.green)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .frame(minHeight: Metrics.rowMinHeight)
            .contentShape(.rect)
            .animation(Motion.snappy, value: copied.isShowing)
        }
        .buttonStyle(RowButtonStyle())
        .accessibilityValue(copied.isShowing ? String(localized: "Copied") : "")
        .debugAnchor("copy-diagnostics")
    }
}
