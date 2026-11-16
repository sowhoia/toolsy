import Foundation
import Observation
import ToolsyEngine
import ToolsyShared

/// What one optimisation achieved, measured rather than assumed.
struct MemoryOptimization: Equatable {
    /// How much more memory the system can hand out at once than before: the growth of free memory
    /// (`MemoryReading.free`), never negative.
    var freed: UInt64
    /// "Memory used" just before and about a second after.
    var usedBefore: UInt64
    var usedAfter: UInt64
    /// Which steps the helper could carry out; `isComplete` is false when the work was done in part.
    var report: MemoryReclaimReport
    var date: Date
}

/// The one-button memory optimisation of the Memory detail: reclaims what can be reclaimed without
/// terminating anything (`SystemMaintaining.reclaimMemory`). When the administrator helper is missing
/// or outdated, it asks in the panel first and installs it, with macOS's password prompt.
@Observable
final class MemoryOptimizer {
    enum Phase: Equatable {
        case idle
        /// The panel asks whether to install or update the helper.
        case asking
        /// Installing the helper (and waiting for the password), reclaiming or measuring.
        case running
        /// Shown for `resultLifetime`, then back to idle.
        case finished(MemoryOptimization)
        /// A message in the user's language; shown for `resultLifetime`, then back to idle.
        case failed(String)
    }

    private(set) var phase: Phase = .idle

    /// Apps answer the pressure warning within moments; memory is read again after this.
    static let settleTime: Duration = .seconds(1)
    static let resultLifetime: Duration = .seconds(30)

    @ObservationIgnored private let helper: any PrivilegedExecuting & SystemMaintaining
    @ObservationIgnored private let store: ModStore
    @ObservationIgnored private let panel: PanelState
    @ObservationIgnored private let readMemory: @MainActor () -> MemoryReading?
    @ObservationIgnored private let clock: any Clock<Duration>
    @ObservationIgnored private var resultExpiry: Task<Void, Never>?

    /// `store` must use `helper`: installing goes through it so that the mods' access is refreshed too.
    init(helper: any PrivilegedExecuting & SystemMaintaining, store: ModStore, panel: PanelState,
         readMemory: @escaping @MainActor () -> MemoryReading? = MemoryReading.read, clock: any Clock<Duration> = ContinuousClock()) {
        self.helper = helper
        self.store = store
        self.panel = panel
        self.readMemory = readMemory
        self.clock = clock
    }

    var isBusy: Bool { phase == .asking || phase == .running }

    /// Starts an optimisation; ignored while one is under way.
    func optimize() {
        guard !isBusy else { return }
        resultExpiry?.cancel()
        phase = .running
        Task { await run() }
    }

    /// Returns a finished or failed optimisation to idle before `resultLifetime` has passed.
    func dismissResult() {
        guard !isBusy else { return }
        resultExpiry?.cancel()
        phase = .idle
    }

    private func run() async {
        let status = await helper.status()
        if status != .ready {
            guard await installHelper(status) else { return }
            phase = .running
        }
        guard let before = readMemory() else { return fail(String(localized: "Toolsy couldn’t read the memory usage.")) }
        let report: MemoryReclaimReport
        do {
            report = try await helper.reclaimMemory()
        } catch {
            return fail(ModInterface.message(for: error, modName: ""))
        }
        guard report.didAnything else {
            // The helper logs why each step failed.
            return fail(String(localized: "Memory couldn’t be freed. Try again in a moment."))
        }
        // Nothing cancels this task, so the sleep runs to its end.
        try? await clock.sleep(for: Self.settleTime)
        guard let after = readMemory() else { return fail(String(localized: "Toolsy couldn’t read the memory usage.")) }
        show(.finished(MemoryOptimization(
            freed: after.free > before.free ? after.free - before.free : 0,
            usedBefore: before.used, usedAfter: after.used, report: report, date: .now
        )))
    }

    /// Asks, then installs or updates the helper. Returns whether it is ready; a declined question or a
    /// dismissed password prompt is an answer, not a failure, and leaves the optimizer idle.
    private func installHelper(_ status: HelperStatus) async -> Bool {
        phase = .asking
        let update = status == .needsUpdate
        let explanation = String(localized: "To free memory, Toolsy clears the disk cache and asks apps to give back memory they don’t need. This needs administrator rights. No app is closed, and nothing you’re working on is lost.")
        // Nobody to ask with the panel closed (it was opened for this, so it closed meanwhile).
        guard panel.isVisible, await panel.ask(ConfirmationRequest(
            title: update ? String(localized: "Update Toolsy’s helper to free memory?") : String(localized: "Install Toolsy’s helper to free memory?"),
            message: ([explanation] + [ModInterface.passwordNotice(for: status)].compactMap(\.self)).joined(separator: "\n\n"),
            icon: "memorychip",
            confirmTitle: update ? String(localized: "Update…") : String(localized: "Install…")
        )) else {
            phase = .idle
            return false
        }
        phase = .running
        panel.confirm(ConfirmationRequest(
            title: String(localized: "Setting up Toolsy’s helper…"),
            message: String(localized: "Enter your administrator password when macOS asks for it."),
            icon: "memorychip",
            confirmTitle: "",
            isProgress: true
        ))
        defer { panel.dismissProgress() }
        do {
            try await panel.holdingOpen { try await store.installHelper() }
            return true
        } catch PrivilegedError.cancelled {
            phase = .idle
            return false
        } catch {
            fail(ModInterface.message(for: error, modName: ""))
            return false
        }
    }

    private func fail(_ message: String) {
        show(.failed(message))
    }

    private func show(_ result: Phase) {
        phase = result
        resultExpiry = Task { [clock] in
            do {
                try await clock.sleep(for: Self.resultLifetime)
            } catch {
                return  // dismissed or replaced by a new optimisation
            }
            if phase == result { phase = .idle }
        }
    }
}
