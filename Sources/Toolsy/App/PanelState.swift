import AppKit
import SwiftUI

/// The pages the panel can show. The root page is the dashboard; everything else is pushed on
/// top of it. Add a case here to add a page (and its view in `PanelRootView.page(for:)`).
enum PanelPage: Hashable, Sendable {
    case root
    case settings
    #if DEBUG
    case gallery
    #endif
    /// The page of the installed mod with this id.
    case mod(String)
}

/// A question asked inside the panel instead of a system alert.
struct ConfirmationRequest: Identifiable {
    let id = UUID()
    var title: String
    var message: String?
    /// Shown on an orange banner under the message: what the user must be warned about.
    var warning: String?
    /// Optional list shown under the message, e.g. the commands a mod will run as root.
    var details: [String] = []
    /// Symbol of the badge next to the title; without one a destructive request shows a warning sign.
    var icon: String?
    var iconTint: Color = .accentColor
    var confirmTitle: String
    /// Nil for a notice that has only the confirm button.
    var cancelTitle: String? = String(localized: "Cancel")
    var isDestructive = false
    /// A notice of work in progress: a spinner instead of buttons, not dismissed by Esc.
    var isProgress = false
    var onConfirm: () -> Void = {}
    var onCancel: () -> Void = {}
}

/// Navigation, in-panel dialogs and visibility of the panel. One instance lives for the life
/// of the app and is in the SwiftUI environment of every page.
@Observable
final class PanelState {
    private(set) var path: [PanelPage] = []
    /// Direction of the last navigation, so the page transition slides the right way.
    private(set) var isNavigatingBack = false
    private(set) var dialog: ConfirmationRequest?
    /// Drives the open/close animation of the content; the window itself is shown before it
    /// becomes true and ordered out after it becomes false.
    var isPresented = false
    /// The tallest the panel's content may be on the current screen.
    var maxHeight: CGFloat = 600
    private(set) var isVisible = false
    /// A file is dragged over the panel; it shows where to drop it.
    var isDropTargeted = false

    @ObservationIgnored private var visibilityHandlers: [(Bool) -> Void] = []
    /// Greater than zero while something outside the panel needs the user (the administrator
    /// prompt); losing focus to it must not close the panel.
    @ObservationIgnored private(set) var holdCount = 0
    /// Set by the panel controller, which keeps the panel open while the open panel is up.
    @ObservationIgnored var chooseFilesHandler: ((NSOpenPanel) async -> [URL])?

    var currentPage: PanelPage { path.last ?? .root }

    // MARK: Navigation

    func push(_ page: PanelPage) {
        guard page != currentPage else { return }
        isNavigatingBack = false
        withAnimation(Motion.gentle) { path.append(page) }
    }

    func pop() {
        guard !path.isEmpty else { return }
        isNavigatingBack = true
        withAnimation(Motion.gentle) { _ = path.removeLast() }
    }

    /// Shows `page` directly on top of the root page (used when opening from the menu).
    func show(_ page: PanelPage) {
        isNavigatingBack = false
        path = page == .root ? [] : [page]
    }

    // MARK: Dialogs

    /// Shows `request`. A dialog still on screen is cancelled first, so every request gets an answer.
    func confirm(_ request: ConfirmationRequest) {
        if dialog != nil { dismissDialog(confirmed: false) }
        withAnimation(Motion.snappy) { dialog = request }
    }

    /// Removes a progress notice shown with `confirm`, unless another dialog has replaced it.
    func dismissProgress() {
        guard dialog?.isProgress == true else { return }
        withAnimation(Motion.snappy) { dialog = nil }
    }

    /// Shows `request` and returns whether it was confirmed. Closing the panel cancels it.
    func ask(_ request: ConfirmationRequest) async -> Bool {
        await withCheckedContinuation { continuation in
            var request = request
            let confirm = request.onConfirm, cancel = request.onCancel
            request.onConfirm = { confirm(); continuation.resume(returning: true) }
            request.onCancel = { cancel(); continuation.resume(returning: false) }
            self.confirm(request)
        }
    }

    /// Keeps the panel open while `work` waits for something outside it, such as a system prompt.
    func holdingOpen<T>(_ work: () async throws -> T) async rethrows -> T {
        holdCount += 1
        defer { holdCount -= 1 }
        return try await work()
    }

    func dismissDialog(confirmed: Bool) {
        guard let request = dialog else { return }
        withAnimation(Motion.snappy) { dialog = nil }
        confirmed ? request.onConfirm() : request.onCancel()
    }

    /// Shows `openPanel` above the panel and returns the chosen files (empty if cancelled).
    func chooseFiles(_ openPanel: NSOpenPanel) async -> [URL] {
        await chooseFilesHandler?(openPanel) ?? []
    }

    // MARK: Visibility

    /// `handler(true)` runs when the panel starts to appear and `handler(false)` after it has
    /// disappeared. Work that only matters while the panel is visible starts and stops here.
    func addVisibilityHandler(_ handler: @escaping (_ isVisible: Bool) -> Void) {
        visibilityHandlers.append(handler)
        if isVisible { handler(true) }
    }

    func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible
        for handler in visibilityHandlers { handler(visible) }
    }
}
