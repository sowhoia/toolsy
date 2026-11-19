import SwiftUI

extension View {
    /// The quiet surface of a group inside the glass panel: a faint fill that separates
    /// content without competing with the material. Increase Contrast adds a visible edge.
    func groupSurface(tint: Color? = nil, radius: CGFloat = Metrics.tileRadius) -> some View {
        modifier(GroupSurface(tint: tint, radius: radius))
    }

    /// The Liquid Glass material of the panel itself and of layers floating above it.
    func panelGlass(radius: CGFloat = Metrics.panelRadius) -> some View {
        modifier(PanelGlass(radius: radius))
    }
}

private struct GroupSurface: ViewModifier {
    let tint: Color?
    let radius: CGFloat
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background {
                shape.fill(Color.primary.opacity(colorScheme == .dark ? 0.07 : 0.05))
                if let tint { shape.fill(tint.opacity(0.14)) }
            }
            .overlay {
                if contrast == .increased {
                    shape.strokeBorder(Color.primary.opacity(0.35), lineWidth: 1)
                } else {
                    GlassRim(shape: shape, intensity: 0.45)
                }
            }
    }
}

private struct PanelGlass: ViewModifier {
    let radius: CGFloat
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        // The glass lies behind the content rather than around it: content inside a glass effect is
        // drawn vibrant, which turns every colour of the panel pastel in Dark Mode (a green switch
        // goes mint) and dull in Light Mode. Behind it, the panel shows the system colours as they are.
        content
            .background { shape.fill(.clear).glassEffect(.regular, in: shape) }
            .overlay {
                if contrast == .increased {
                    shape.strokeBorder(Color.primary.opacity(0.5), lineWidth: 1)
                }
            }
    }
}

/// A tile: the basic group of the panel. Pass `action` for a clickable tile, `tint` for a
/// mod's colour.
struct Tile<Content: View>: View {
    private let tint: Color?
    private let padding: CGFloat
    private let action: (() -> Void)?
    private let content: Content

    init(tint: Color? = nil, padding: CGFloat = Metrics.tilePadding, action: (() -> Void)? = nil,
         @ViewBuilder content: () -> Content) {
        self.tint = tint
        self.padding = padding
        self.action = action
        self.content = content()
    }

    var body: some View {
        if let action {
            Button(action: action) { padded }
                .buttonStyle(TileButtonStyle(tint: tint))
        } else {
            padded.groupSurface(tint: tint)
        }
    }

    private var padded: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct TileButtonStyle: ButtonStyle {
    let tint: Color?
    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(.rect(cornerRadius: Metrics.tileRadius))
            .background {
                RoundedRectangle(cornerRadius: Metrics.tileRadius, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.08 : isHovered ? 0.045 : 0))
            }
            .groupSurface(tint: tint)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .opacity(isEnabled ? 1 : 0.5)
            .animation(Motion.snappy, value: configuration.isPressed)
            .animation(Motion.fade, value: isHovered)
            .onHover { isHovered = $0 }
    }
}

/// A one-pixel separator between rows.
struct Hairline: View {
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(height: 1 / displayScale)
    }
}

extension ContainerValues {
    /// Marks a row of a `SectionGroup` that separates two groups of rows; see `SectionBreak`.
    @Entry var isSectionBreak = false
}

/// A stronger separation between groups of rows inside one `SectionGroup`: a band across the tile
/// in place of a hairline (a mod's `divider`).
struct SectionBreak: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.06))
            .frame(height: 6)
            .padding(.horizontal, -Metrics.tilePadding)
            .padding(.vertical, 5)
            .containerValue(\.isSectionBreak, true)
            .accessibilityHidden(true)
    }
}

/// A titled group of rows on one tile, separated by hairlines, with an optional footer. With
/// `isExpanded` the title folds the group: folded, only the title is shown and the rows are not rendered.
struct SectionGroup<Content: View>: View {
    private let title: String?
    private let footer: String?
    private let tint: Color?
    private let isExpanded: Binding<Bool>?
    private let content: Content

    init(_ title: String? = nil, footer: String? = nil, tint: Color? = nil, isExpanded: Binding<Bool>? = nil,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.tint = tint
        self.isExpanded = isExpanded
        self.content = content()
    }

    var body: some View {
        let title = title.flatMap { $0.isEmpty ? nil : $0 }
        // Only a title can be clicked to fold the group.
        let expanded = title == nil || isExpanded?.wrappedValue != false
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                if let isExpanded {
                    // A row tall, its text where a plain title's is; folded, the tile is a header's height.
                    FoldableTitle(title, isExpanded: isExpanded)
                        .padding(.horizontal, Metrics.tilePadding)
                        .padding(.top, 6)
                        .padding(.bottom, expanded ? 0 : 6)
                } else {
                    Text(title)
                        .font(.tileTitle)
                        .foregroundStyle(.secondary)
                        .accessibilityAddTraits(.isHeader)
                        .padding(.horizontal, Metrics.tilePadding)
                        .padding(.top, 12)
                        .padding(.bottom, 2)
                }
            }
            if expanded {
                rows
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .groupSurface(tint: tint)
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Group(subviews: content) { rows in
                    // A section break draws its own separation, so the hairlines next to it are left out.
                    let afterBreak = Set(zip(rows.dropFirst(), rows).filter { $0.1.containerValues.isSectionBreak }.map(\.0.id))
                    ForEach(rows) { row in
                        if row.containerValues.isSectionBreak {
                            row
                        } else {
                            if row.id != rows.first?.id, !afterBreak.contains(row.id) {
                                Hairline()
                            }
                            row.padding(.vertical, 7)
                        }
                    }
                }
            }
            .padding(.horizontal, Metrics.tilePadding)
            .padding(.vertical, 5)
            if let footer, !footer.isEmpty {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Metrics.tilePadding)
                    .padding(.bottom, 12)
            }
        }
    }
}

/// A page of the panel: a header with back button, title and trailing accessory, and content
/// that scrolls once it is taller than the screen allows, with its edges fading out.
struct PageScaffold<Accessory: View, Content: View>: View {
    private let title: String
    private let subtitle: String?
    private let badge: PageBadge?
    private let accessory: Accessory
    private let content: Content

    @Environment(PanelState.self) private var panel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var edges = ScrollEdges()

    /// `subtitle` and `badge` give a page about one thing (a mod) its name, icon and details.
    init(_ title: String, subtitle: String? = nil, badge: PageBadge? = nil, @ViewBuilder content: () -> Content,
         @ViewBuilder accessory: () -> Accessory = { EmptyView() }) {
        self.title = title
        self.subtitle = subtitle
        self.badge = badge
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        // The content is inset by `edgeRoom` inside the scroll view so glass at its edges (a
        // button's rim) is not clipped; the spacing under the header gives that room back.
        let edgeRoom: CGFloat = 2
        ScrollViewReader { proxy in
            VStack(spacing: Metrics.tileSpacing - edgeRoom) {
                PageHeader(title: title, subtitle: subtitle, badge: badge, showsBack: !panel.path.isEmpty, onBack: panel.pop) {
                    accessory
                }
                ContentHeight(limit: max(0, panel.maxHeight - 2 * Metrics.panelPadding
                                            - Metrics.headerHeight - Metrics.tileSpacing + edgeRoom)) {
                    ScrollView {
                        VStack(spacing: Metrics.tileSpacing) { content }
                            .padding(.vertical, edgeRoom)
                    }
                    .scrollIndicators(.automatic)
                    .debugAnchor("scroll")
                    .onScrollGeometryChange(for: ScrollEdges.self, of: ScrollEdges.init) { _, new in edges = new }
                    .mask { EdgeFadeMask(edges: edges) }
                }
            }
            .onChange(of: panel.scrollTarget) { _, target in
                guard let target else { return }
                panel.scrollTarget = nil
                withAnimation(Motion.resolve(Motion.gentle, reduceMotion: reduceMotion)) { proxy.scrollTo(target, anchor: .top) }
            }
        }
    }
}

/// Gives a scroll view the height of its content, up to a limit beyond which it scrolls. The height
/// is part of the layout, so it changes in the same transaction as the content and animates with it.
/// Measured into state instead, it arrived a frame late and unanimated: a page appeared at zero
/// height, and a group that collapsed cut off everything below it until the rows had moved up.
private struct ContentHeight: Layout {
    let limit: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let scrollView = subviews.first else { return .zero }
        // Without a proposed height a scroll view asks for all of its content.
        let content = scrollView.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: proposal.width ?? content.width, height: min(content.height, limit))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}

/// Which ends of a scroll view have more content beyond them.
private struct ScrollEdges: Equatable {
    var top = false
    var bottom = false

    init() {}

    init(_ geometry: ScrollGeometry) {
        top = geometry.contentOffset.y > 1
        bottom = geometry.contentOffset.y + geometry.containerSize.height < geometry.contentSize.height - 1
    }
}

private struct EdgeFadeMask: View {
    let edges: ScrollEdges
    private let fade: CGFloat = 18

    var body: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.black.opacity(edges.top ? 0 : 1), .black], startPoint: .top, endPoint: .bottom)
                .frame(height: fade)
            Rectangle()
            LinearGradient(colors: [.black, .black.opacity(edges.bottom ? 0 : 1)], startPoint: .top, endPoint: .bottom)
                .frame(height: fade)
        }
        .animation(Motion.fade, value: edges)
    }
}

/// The icon of a page header; unlit for a mod that is switched off.
struct PageBadge {
    var symbol: String
    var tint: Color
    var isLit = true
}

/// The header bar of a page.
struct PageHeader<Accessory: View>: View {
    let title: String
    var subtitle: String?
    var badge: PageBadge?
    let showsBack: Bool
    let onBack: () -> Void
    @ViewBuilder let accessory: Accessory

    var body: some View {
        HStack(spacing: 8) {
            if showsBack {
                IconButton("chevron.left", label: String(localized: "Back"), action: onBack)
                    .keyboardShortcut("[", modifiers: .command)
                    .debugAnchor("back")
            }
            if let badge {
                IconBadge(badge.symbol, tint: badge.tint, size: 28, isLit: badge.isLit)
                    .padding(.leading, showsBack ? 0 : 6)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.leading, showsBack || badge != nil ? 0 : 9)
            Spacer(minLength: 8)
            accessory
        }
        // Round buttons sit as far from the side of the glass as from its top, concentric with its corner.
        .padding(.horizontal, (Metrics.headerHeight - Metrics.iconButtonSize) / 2)
        .frame(height: Metrics.headerHeight)
    }
}
