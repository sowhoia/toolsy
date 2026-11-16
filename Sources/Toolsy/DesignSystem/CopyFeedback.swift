import AppKit
import Observation

/// Copies text to the general pasteboard and says so for a moment: the confirmation of a copyable
/// value row and of a mod's copy button. Keep one in `@State` per control.
@Observable
final class CopyFeedback {
    /// True for a moment after each copy; the control shows "Copied" meanwhile.
    private(set) var isShowing = false
    @ObservationIgnored private var resetTask: Task<Void, Never>?

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        isShowing = true
        resetTask?.cancel()
        resetTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(1.4)) } catch { return }  // cancelled by a newer copy
            self?.isShowing = false
        }
    }
}
