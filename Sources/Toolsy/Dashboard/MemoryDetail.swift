import SwiftUI
import ToolsyShared

/// What the Memory detail says about the optimisation, in plain words and true in every case.
struct OptimizationMessage: Equatable {
    enum Tone: Equatable {
        /// Before the button is pressed: what it does.
        case about
        case working
        case freed
        case nothingFreed
        case partial
        case failed
    }

    var tone: Tone
    var title: String
    var detail: String?

    /// Memory used moves by itself, and free memory with it while the file cache stays put: from one second
    /// to the next free memory changed by 12 MB at the median and 117 MB at the 90th percentile on a 16 GB
    /// Mac at rest (`vm_stat 1`, 28 samples), and memory used by 52 MB and 176 MB on the same Mac in use
    /// (30 samples). A fall below 1 % of the memory (164 MB there) is that noise, and too little to matter,
    /// so it is not called freed.
    static func noticeable(total: UInt64) -> UInt64 {
        total / 100
    }

    init(_ phase: MemoryOptimizer.Phase, total: UInt64) {
        switch phase {
        case .idle, .asking:
            // While asking, the panel's dialog explains the rest.
            self.init(.about, String(localized: "Clears caches and asks apps to return memory they don’t need. No app is closed."))
        case .running:
            self.init(.working, String(localized: "Freeing memory…"),
                      detail: String(localized: "Apps keep running."))
        case .failed(let message):
            self.init(.failed, message)
        case .finished(let result):
            let freed = result.freed >= Self.noticeable(total: total) ? Format.memory(result.freed) : nil
            // Apart from what was freed: cached files were there for the taking all along, so clearing them
            // gains nothing, and the Mac reads those files from disk again when it needs them.
            let cache = result.report.diskCacheFlushed
                ? String(localized: "Cached files: \(Format.memory(result.cachedBefore)) → \(Format.memory(result.cachedAfter))") : nil
            if result.report.isComplete {
                let used = String(localized: "Memory used: \(Format.memory(result.usedBefore)) → \(Format.memory(result.usedAfter))")
                let detail = [used, cache].compactMap(\.self).joined(separator: "\n")
                if let freed {
                    self.init(.freed, String(localized: "\(freed) freed"), detail: detail)
                } else {
                    self.init(.nothingFreed, String(localized: "Nothing to free right now"), detail: detail)
                }
            } else {
                let failure = result.report.diskCacheFlushed ? String(localized: "Apps couldn’t be asked to return memory.")
                                                             : String(localized: "The disk cache couldn’t be cleared.")
                self.init(.partial,
                          freed.map { String(localized: "Done in part: \($0) freed") } ?? String(localized: "Done in part: nothing freed"),
                          detail: [failure, cache].compactMap(\.self).joined(separator: "\n"))
            }
        }
    }

    private init(_ tone: Tone, _ title: String, detail: String? = nil) {
        self.tone = tone
        self.title = title
        self.detail = detail
    }

    /// What an optimisation came to, rather than what it does or that it is under way.
    var isResult: Bool {
        ![.about, .working].contains(tone)
    }

    /// What VoiceOver says when the optimisation ends, which happens seconds after the button was pressed,
    /// wherever the user's focus is by then. Nil before and while it runs.
    var announcement: String? {
        isResult ? [title, detail].compactMap(\.self).joined(separator: "\n") : nil
    }
}

/// The Memory detail: how the memory is used, the one-button optimisation, and the apps that hold the most.
struct MemoryDetail: View {
    @Environment(SystemMonitor.self) private var monitor
    @Environment(MemoryOptimizer.self) private var optimizer

    var body: some View {
        if let memory = monitor.memory {
            let used = Double(memory.used) / Double(max(memory.total, 1))
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 14) {
                    // In whole percents, as its text reads: following every few megabytes would animate the
                    // ring and its digits every second, a cost on every frame for a change nobody can see.
                    RingGauge(value: (used * 100).rounded(), text: Format.percent(used), tint: memoryTint(memory.pressure), size: 56)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(String(localized: "\(Format.memory(memory.used)) of \(Format.memory(memory.total))"))
                                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                                .lineLimit(1)
                            Spacer(minLength: 6)
                            StatusLabel(pressureText(memory.pressure), level: pressureLevel(memory.pressure))
                        }
                        GlassButton(String(localized: "Free Up Memory"), icon: "sparkles", kind: .prominent,
                                    isBusy: optimizer.isBusy, fillsWidth: true, action: optimizer.optimize)
                            .debugAnchor("memory-optimize")
                    }
                }
                OptimizationStatus(message: OptimizationMessage(optimizer.phase, total: memory.total),
                                   onDismiss: optimizer.dismissResult)
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    GridRow {
                        DetailFact(label: String(localized: "Apps"), value: Format.memory(memory.app))
                        DetailFact(label: String(localized: "Wired"), value: Format.memory(memory.wired))
                        DetailFact(label: String(localized: "Compressed"), value: Format.memory(memory.compressed))
                    }
                    GridRow {
                        DetailFact(label: String(localized: "Cached files"), value: Format.memory(memory.cachedFiles))
                        DetailFact(label: String(localized: "Free"), value: Format.memory(memory.free))
                        DetailFact(label: String(localized: "Swap"), value: Format.memory(memory.swapUsed))
                    }
                }
                ProcessList(title: String(localized: "Using the most memory"), measure: .memory, count: 5)
            }
            .debugAnchor("detail:memory")
        }
    }

    private func pressureText(_ pressure: MemoryPressure) -> String {
        switch pressure {
        case .normal: String(localized: "Pressure normal")
        case .warning: String(localized: "Pressure elevated")
        case .critical: String(localized: "Pressure critical")
        }
    }

    private func pressureLevel(_ pressure: MemoryPressure) -> StatusLevel {
        switch pressure {
        case .normal: .ok
        case .warning: .warn
        case .critical: .error
        }
    }
}

/// The line under the optimise button: what it does, then what it is doing, then what it achieved. It
/// keeps its height in every state but a longer message's.
private struct OptimizationStatus: View {
    let message: OptimizationMessage
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(tint ?? .secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(message.title)
                    .font(message.tone == .about ? .caption : .system(size: 12, weight: .semibold))
                    .foregroundStyle(message.tone == .about ? .secondary : .primary)
                if let detail = message.detail {
                    Text(detail)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            if message.isResult {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(RowButtonStyle())
                .foregroundStyle(.secondary)
                .help(String(localized: "Dismiss"))
                .accessibilityLabel(String(localized: "Dismiss"))
                .debugAnchor("memory-dismiss")
            }
        }
        .padding(.vertical, 8)
        .background {
            // Reaches a little past the text, as the highlight of a row does, so the text stays in line
            // with the rest of the detail.
            RoundedRectangle(cornerRadius: Metrics.innerRadius, style: .continuous)
                .fill(tint?.opacity(0.14) ?? Color.primary.opacity(message.tone == .about ? 0 : 0.06))
                .padding(.horizontal, -8)
        }
        .animation(Motion.fade, value: message)
        .onChange(of: message) { _, message in
            if let announcement = message.announcement { VoiceOver.announce(announcement) }
        }
        .debugAnchor("memory-status")
    }

    private var symbol: String {
        switch message.tone {
        case .about: "info.circle"
        case .working: "hourglass"
        case .freed: "checkmark.circle.fill"
        case .nothingFreed: "checkmark.circle"
        case .partial: "exclamationmark.triangle.fill"
        case .failed: "exclamationmark.octagon.fill"
        }
    }

    /// Nil for the neutral states.
    private var tint: Color? {
        switch message.tone {
        case .about, .working, .nothingFreed: nil
        case .freed: .green
        case .partial: .orange
        case .failed: .red
        }
    }
}
