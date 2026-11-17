import AppKit
import Observation

/// Copies text to the general pasteboard and says so for a moment: the confirmation of a copyable
/// value row and of a mod's copy button. Keep one in `@State` per control.
@Observable
final class CopyFeedback {
    /// True for a moment after each copy; the control shows "Copied" meanwhile.
    private(set) var isShowing = false
    @ObservationIgnored private var resetTask: Task<Void, Never>?
    @ObservationIgnored private let pasteboard: NSPasteboard
    @ObservationIgnored private let announce: @MainActor (String) -> Void

    init(pasteboard: NSPasteboard = .general, announce: @escaping @MainActor (String) -> Void = VoiceOver.announce) {
        self.pasteboard = pasteboard
        self.announce = announce
    }

    func copy(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        isShowing = true
        // The control's label changes where VoiceOver's focus already is, and is not read again by itself.
        announce(String(localized: "Copied"))
        resetTask?.cancel()
        resetTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(1.4)) } catch { return }  // cancelled by a newer copy
            self?.isShowing = false
        }
    }
}
