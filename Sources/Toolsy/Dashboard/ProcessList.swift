import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// What a process list ranks the apps by.
enum ProcessMeasure {
    case memory, cpu

    func value(of group: ProcessGroup) -> Double {
        switch self {
        case .memory: Double(group.memory)
        case .cpu: group.cpu
        }
    }

    /// How much more than the row above it a row must have to move above it. Smaller differences are
    /// the drift of a few seconds, and following them would swap rows back and forth.
    func reorderMargin(above value: Double) -> Double {
        switch self {
        case .memory: value * 0.05
        // CPU use jumps from sample to sample; 2 is 2 % of one core.
        case .cpu: max(value * 0.25, 2)
        }
    }

    /// Memory as Activity Monitor shows it; CPU in its unit too, 100 % being one core, with a decimal
    /// below 10 % so that light use does not all read "0 %".
    func format(_ group: ProcessGroup) -> String {
        switch self {
        case .memory: Format.memory(group.memory)
        case .cpu: (group.cpu / 100).formatted(.percent.precision(.fractionLength(group.cpu < 10 ? 1 : 0)))
        }
    }
}

/// One app of a process list, ready to show.
struct ProcessRow: Identifiable, Equatable {
    let group: ProcessGroup
    let value: String
    /// "×3" beside the name of an app that runs several processes.
    let processCount: String?
    /// Only the memory list offers to quit: that is where quitting an app is the answer.
    let offersQuit: Bool

    var id: String { group.id }

    init(_ group: ProcessGroup, measure: ProcessMeasure) {
        self.group = group
        value = measure.format(group)
        processCount = group.processCount > 1 ? "×\(group.processCount)" : nil
        offersQuit = measure == .memory && group.canQuit
    }

    /// The groups a list of `count` rows shows, given `ranked` (every candidate, highest first) and the ids
    /// it showed before: the highest ones, except that a row already shown keeps its place in the list
    /// until the group that would replace it has noticeably more (`ProcessMeasure.reorderMargin`). Without
    /// this the last row of a list changes with every sample: on an idle Mac the fourth and fifth busiest
    /// apps are a fraction of a percent apart.
    static func members(of ranked: [ProcessGroup], count: Int, previous: [String], by measure: ProcessMeasure) -> [ProcessGroup] {
        var members = Array(ranked.prefix(count))
        let shown = Set(previous)
        // Shown before and now just outside, strongest first; each may hold on against the weakest newcomer.
        for incumbent in ranked.dropFirst(count) where shown.contains(incumbent.id) {
            guard let weakest = members.lastIndex(where: { !shown.contains($0.id) }) else { break }
            let held = measure.value(of: incumbent)
            guard measure.value(of: members[weakest]) <= held + measure.reorderMargin(above: held) else { break }
            members[weakest] = incumbent
        }
        return members
    }

    /// The order a list shows `top` (the groups that belong in it, highest first) in, given the ids it
    /// showed before: rows keep their places until one has noticeably more than the row above it
    /// (`ProcessMeasure.reorderMargin`); rows new to the list start below the others and rise as far as
    /// they have more.
    static func order(_ top: [ProcessGroup], previous: [String], by measure: ProcessMeasure) -> [ProcessGroup] {
        let shownAt = Dictionary(previous.enumerated().map { ($1, $0) }, uniquingKeysWith: min)
        var rows = top.enumerated()
            .sorted { (shownAt[$0.element.id] ?? Int.max, $0.offset) < (shownAt[$1.element.id] ?? Int.max, $1.offset) }
            .map(\.element)
        // Each swap puts the larger value first, removing an inversion, so this ends.
        var swapped = true
        while swapped {
            swapped = false
            for index in rows.indices.dropFirst() {
                let upper = measure.value(of: rows[index - 1])
                if measure.value(of: rows[index]) > upper + measure.reorderMargin(above: upper) {
                    rows.swapAt(index - 1, index)
                    swapped = true
                }
            }
        }
        return rows
    }
}

/// The apps that hold the most memory or use the most CPU, for the memory and CPU details. Processes
/// are sampled only while a list is on screen. The list is as tall as `count` rows from its first frame
/// on, so the panel keeps its height while the first sample is taken and as rows come and go.
struct ProcessList: View {
    let title: String
    let measure: ProcessMeasure
    let count: Int

    @Environment(ProcessMonitor.self) private var monitor
    @Environment(PanelState.self) private var panel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var rows: [ProcessRow] = []

    static let rowHeight: CGFloat = 24
    static let rowSpacing: CGFloat = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.tileTitle)
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: Self.rowSpacing) {
                if monitor.groups.isEmpty {
                    ForEach(0..<count, id: \.self) { PlaceholderRow(index: $0) }
                } else {
                    let quittable = rows.filter(\.offersQuit).map(\.id)
                    ForEach(rows) { row in
                        ProcessRowView(row: row, reservesQuitSpace: measure == .memory,
                                       quitAnchor: "process-quit:\(quittable.firstIndex(of: row.id) ?? 0)") { askToQuit(row.group) }
                            .transition(.opacity)
                    }
                }
            }
            .frame(height: CGFloat(count) * Self.rowHeight + CGFloat(count - 1) * Self.rowSpacing, alignment: .top)
        }
        .onAppear(perform: monitor.start)
        .onDisappear(perform: monitor.stop)
        .onChange(of: monitor.groups, initial: true) { update() }
        .debugAnchor("process-list:\(measure)")
    }

    private func update() {
        let shown = rows.map(\.id)
        // A row that dropped out of the top can only hold on from just below it.
        let ranked = measure == .memory ? monitor.largest(count + shown.count) : monitor.busiest(count + shown.count)
        let top = ProcessRow.members(of: ranked, count: count, previous: shown, by: measure)
        let updated = ProcessRow.order(top, previous: shown, by: measure).map { ProcessRow($0, measure: measure) }
        // New values alone change no geometry worth animating; moving rows glide to their places.
        if updated.map(\.id) == rows.map(\.id) {
            rows = updated
        } else {
            withAnimation(Motion.resolve(Motion.gentle, reduceMotion: reduceMotion)) { rows = updated }
        }
    }

    private func askToQuit(_ group: ProcessGroup) {
        panel.confirm(ConfirmationRequest(
            title: String(localized: "Quit “\(group.name)”?"),
            message: String(localized: "“\(group.name)” may ask you to save changes first. Nothing is forced to close."),
            icon: "xmark.circle",
            iconTint: .orange,
            confirmTitle: String(localized: "Quit"),
            onConfirm: { quit(group) }
        ))
    }

    private func quit(_ group: ProcessGroup) {
        guard !monitor.quit(group) else { return }
        panel.confirm(ConfirmationRequest(
            title: String(localized: "“\(group.name)” couldn’t be asked to quit"),
            message: String(localized: "It may have quit already."),
            confirmTitle: String(localized: "OK"),
            cancelTitle: nil
        ))
    }
}

private struct ProcessRowView: View {
    let row: ProcessRow
    /// Keeps the values of rows without a quit control in line with those that have one.
    let reservesQuitSpace: Bool
    /// Scripts find the quit control of the n-th row that has one by this name.
    let quitAnchor: String
    let onQuit: () -> Void

    @State private var isQuitHovered = false

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                AppIcon(image: row.group.icon)
                Text(row.group.name)
                    .font(.rowLabel)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let count = row.processCount {
                    Text(count)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .fixedSize()
                }
                Spacer(minLength: 8)
                Text(row.value)
                    .font(.rowValue)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
                    // Values change every few seconds; animating their glyphs costs CPU on every frame.
                    .contentTransition(.identity)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(row.group.name)
            .accessibilityValue(accessibilityValue)
            if row.offersQuit {
                quitButton
            } else if reservesQuitSpace {
                Color.clear.frame(width: Self.quitSize, height: Self.quitSize)
            }
        }
        .frame(height: ProcessList.rowHeight)
    }

    private static let quitSize: CGFloat = 20

    /// Small, at the far end of the row and dim until pointed at, so it is not hit by accident; it only
    /// asks, and the panel's dialog confirms.
    private var quitButton: some View {
        Button(action: onQuit) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 13))
                .frame(width: Self.quitSize, height: Self.quitSize)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isQuitHovered ? .secondary : .tertiary)
        .onHover { isQuitHovered = $0 }
        .animation(Motion.fade, value: isQuitHovered)
        .help(String(localized: "Quit “\(row.group.name)”…"))
        .debugAnchor(quitAnchor)
        .accessibilityLabel(String(localized: "Quit “\(row.group.name)”…"))
    }

    private var accessibilityValue: String {
        guard row.group.processCount > 1 else { return row.value }
        return "\(row.value), " + String(localized: "processes: \(row.group.processCount)")
    }
}

/// An app's icon at row size. The images are the ones `ProcessMonitor` keeps per app, never made here.
private struct AppIcon: View {
    let image: NSImage?

    var body: some View {
        Image(nsImage: image ?? Self.executable)
            .resizable()
            .interpolation(.high)
            .frame(width: 20, height: 20)
            .accessibilityHidden(true)
    }

    /// Processes outside an app bundle look as in Activity Monitor.
    private static let executable = NSWorkspace.shared.icon(for: .unixExecutable)
}

/// A grey row standing in for an app until the first sample arrives.
private struct PlaceholderRow: View {
    let index: Int

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .frame(width: 20, height: 20)
            Capsule()
                .frame(width: [96, 72, 112, 84, 64][index % 5], height: 8)
            Spacer(minLength: 8)
            Capsule()
                .frame(width: 44, height: 8)
        }
        .foregroundStyle(.quaternary)
        .frame(height: ProcessList.rowHeight)
        .accessibilityHidden(true)
    }
}
