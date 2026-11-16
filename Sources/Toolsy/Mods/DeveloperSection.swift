import AppKit
import SwiftUI
import ToolsyEngine

/// The end of a mod's page in developer mode: reloading the mod, its folder, and what it ran lately.
struct DeveloperSection: View {
    let mod: Mod
    @Environment(ModsModel.self) private var model

    var body: some View {
        SectionGroup(String(localized: "Developer")) {
            ListRow(String(localized: "Show in Finder"), icon: "folder.fill", tint: .blue) {
                NSWorkspace.shared.activateFileViewerSelecting([mod.folder])
            }
            .debugAnchor("mod-folder")
            GlassButton(String(localized: "Reload"), icon: "arrow.clockwise", isBusy: model.reloading.contains(mod.id),
                        fillsWidth: true) {
                model.reload(mod)
            }
            .debugAnchor("mod-reload")
        }
        RecentRuns(mod: mod)
    }
}

/// The mod's recent runs, newest first. The only view that reads `recentRuns`, so recording a run
/// re-renders this list and nothing else on the page.
private struct RecentRuns: View {
    let mod: Mod

    var body: some View {
        SectionGroup(String(localized: "Recent Runs")) {
            if mod.recentRuns.isEmpty {
                Text("Nothing has run yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: Metrics.rowMinHeight)
            } else {
                ForEach(mod.recentRuns.reversed()) { run in
                    RunRow(run: run)
                }
            }
        }
        .debugAnchor("recent-runs")
    }
}

/// One run: what ran, why, how it ended and how long it took; for a failure, the end of its standard
/// error, folded to its last line until clicked.
private struct RunRow: View {
    let run: CommandRun
    @State private var showsError = false

    var body: some View {
        let failed = ModInterface.isFailure(run.outcome)
        let details = [ModInterface.durationText(of: run), run.started.formatted(date: .omitted, time: .standard)]
            .compactMap(\.self).joined(separator: " · ")
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                symbol(failed: failed)
                    .font(.system(size: 12))
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(run.command)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(details)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Text(ModInterface.text(for: run.event) + " · " + ModInterface.text(for: run.outcome))
                        .font(.caption)
                        .foregroundStyle(failed ? .red : .secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
            let standardError = run.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            if failed, !standardError.isEmpty {
                standardErrorView(standardError)
                    .padding(.leading, 20)
            }
        }
    }

    private func symbol(failed: Bool) -> some View {
        let (name, color): (String, Color) = switch run.outcome {
        case _ where failed: ("xmark.octagon.fill", .red)
        case .succeeded: ("checkmark.circle.fill", .green)
        case .started, .restarted: ("play.circle.fill", .blue)
        default: ("stop.circle.fill", .gray)  // a service that ended with status 0
        }
        return Image(systemName: name).foregroundStyle(color)
    }

    private func standardErrorView(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(Motion.snappy) { showsError.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(showsError ? 90 : 0))
                    Text("Standard error")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityValue(showsError ? String(localized: "Expanded") : String(localized: "Collapsed"))
            .debugAnchor("run-error")
            Text(showsError ? text : text.split(separator: "\n").last.map(String.init) ?? text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.primary.opacity(0.85))
                .lineLimit(showsError ? nil : 1)
                .truncationMode(.head)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background {
                    RoundedRectangle(cornerRadius: Metrics.innerRadius - 2, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                }
        }
    }
}
