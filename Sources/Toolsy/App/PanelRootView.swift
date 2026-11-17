import SwiftUI

/// The SwiftUI root of the panel: the current page, page transitions, the in-panel dialog and
/// the open/close animation. The panel takes the height of its page at the top of a window that
/// is as tall as the panel may get (see `PanelPlacement`).
struct PanelRootView: View {
    @Environment(PanelState.self) private var panel
    @Environment(ModsModel.self) private var mods
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .top) {
            ZStack(alignment: .top) {
                page(for: panel.currentPage)
                    .id(panel.currentPage)
                    .transition(PageTransition(panel: panel, reduceMotion: reduceMotion))
            }
            .opacity(panel.dialog == nil ? 1 : 0.35)
            .blur(radius: panel.dialog == nil || reduceMotion ? 0 : 2)
            .allowsHitTesting(panel.dialog == nil)
            // Its keyboard shortcuts too: Return would also press the page's default button (Done while the
            // dashboard is edited), and ⌘[ would go back underneath the dialog. The dialog stays enabled.
            .disabled(panel.dialog != nil)
            .accessibilityHidden(panel.dialog != nil)
            .overlay {
                if panel.isDropTargeted {
                    DropTarget().transition(.opacity)
                }
            }

            if let request = panel.dialog {
                ConfirmationDialog(
                    request: request,
                    onConfirm: { panel.dismissDialog(confirmed: true) },
                    onCancel: { panel.dismissDialog(confirmed: false) }
                )
                .padding(.top, Metrics.headerHeight + Metrics.tileSpacing)
                .transition(.scale(scale: reduceMotion ? 1 : 0.94).combined(with: .opacity))
                .zIndex(1)
            }
        }
        .padding(Metrics.panelPadding)
        .frame(width: Metrics.panelWidth)
        .animation(Motion.fade, value: panel.isDropTargeted)
        // Mod packages dropped anywhere on the panel are installed, one confirmation each.
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            mods.install(files)
            return !files.isEmpty
        } isTargeted: { targeted in
            panel.isDropTargeted = targeted
        }
        // Nothing draws past the glass: shadows of the dialog and of controls near the edge stop at it.
        .clipShape(RoundedRectangle(cornerRadius: Metrics.panelRadius, style: .continuous))
        .panelGlass()
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { panel.glassFrame = $0 }
        .debugAnchor("panel")
        .padding(Metrics.panelInset)
        .scaleEffect(panel.isPresented || reduceMotion ? 1 : 0.96, anchor: .top)
        .offset(y: panel.isPresented || reduceMotion ? 0 : -6)
        .opacity(panel.isPresented ? 1 : 0)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private func page(for page: PanelPage) -> some View {
        switch page {
        case .root: RootPage()
        case .settings: SettingsPage()
        #if DEBUG
        case .gallery: GalleryPage()
        #endif
        case .mod(let id): ModPage(id: id)
        }
    }
}

/// Covers the panel while a file is dragged over it, so it is clear that dropping installs it.
private struct DropTarget: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.tileRadius, style: .continuous)
        VStack(spacing: 8) {
            Image(systemName: "square.and.arrow.down.fill")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(Color.accentColor)
            Text("Drop to install")
                .font(.system(size: 14, weight: .semibold))
            Text("Toolsy asks before it installs anything.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            shape.fill(.regularMaterial)
            shape.fill(Color.accentColor.opacity(0.1))
        }
        .overlay {
            shape.strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
        }
        .allowsHitTesting(false)
    }
}

/// Pages slide in from the trailing edge when pushed and from the leading edge when popped.
/// The direction is read when the transition runs, not when the outgoing page last rendered,
/// so the outgoing page always leaves the opposite way. The page that leaves has faded before the
/// one that arrives shows, so the text of one is never read through the other.
private struct PageTransition: Transition {
    let panel: PanelState
    let reduceMotion: Bool

    func body(content: Content, phase: TransitionPhase) -> some View {
        let direction: CGFloat = panel.isNavigatingBack ? -1 : 1
        let offset: CGFloat = switch phase {
        case .willAppear: direction * 60
        case .identity: 0
        case .didDisappear: -direction * 60
        }
        content
            .offset(x: reduceMotion ? 0 : offset)
            .animation(phase == .didDisappear ? .easeOut(duration: 0.1) : .easeIn(duration: 0.18).delay(0.06)) {
                $0.opacity(phase.isIdentity ? 1 : 0)
            }
    }
}
