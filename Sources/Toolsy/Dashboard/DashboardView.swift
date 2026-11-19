import SwiftUI
import ToolsyEngine

/// A widget of the layout that can be shown now, with its options resolved.
struct ShownWidget: Identifiable {
    let placed: PlacedWidget
    let info: WidgetInfo
    /// In edit mode a mod widget whose `when` is false is shown dimmed, so it can still be arranged.
    var isConditionHidden = false

    var id: WidgetID { placed.id }
    var size: WidgetSize { placed.size ?? info.defaultSize }
    var chartStyle: ChartStyle { placed.chartStyle ?? info.defaultChartStyle ?? .line }
    var rateUnit: RateUnit { placed.rateUnit ?? .bytes }

    /// A mod widget without `detail` opens the mod's page instead.
    var hasDetail: Bool {
        if case .mod(_, let widget, _) = info.content { !widget.detail.isEmpty } else { true }
    }
}

/// A brief summary of the Mac at the top of the root page: a device line and the grid of widgets the
/// user arranged. Clicking a tile opens its details right under its row; clicking it again (or another
/// tile) closes them. Every tile reads only the readings it shows, so a new sample re-renders only what
/// changed, and details that are closed cost nothing. In edit mode the tiles are moved by dragging,
/// selected for their options and removed.
struct DashboardView: View {
    @Environment(SystemMonitor.self) private var monitor
    @Environment(PanelState.self) private var panel
    @Environment(DashboardStore.self) private var store
    @Environment(ModsModel.self) private var mods
    @State private var expanded: WidgetID?
    @State private var selected: WidgetID?

    var body: some View {
        let widgets = shownWidgets
        VStack(spacing: Metrics.tileSpacing) {
            if store.layout.showsDeviceLine {
                DeviceLine()
                    .transition(.opacity)
            }
            if widgets.isEmpty {
                EmptyDashboard()
            } else {
                WidgetGrid(widgets: widgets, expanded: $expanded, selected: $selected)
            }
        }
        .onChange(of: panel.isVisible) { _, visible in
            if !visible { expanded = nil }  // every opening starts collapsed
        }
        .onChange(of: expanded) { _, id in
            monitor.wantsInterfaceUpdates = id == .builtIn(.network)
        }
        // Another page takes this view's place and its `expanded` with it.
        .onDisappear { monitor.wantsInterfaceUpdates = false }
        .onChange(of: store.isEditing) {
            expanded = nil
            selected = nil
        }
        .onChange(of: Set(widgets.compactMap(\.id.metric)), initial: true) { _, metrics in
            monitor.shownMetrics = metrics
        }
    }

    /// The placed widgets this Mac and the installed mods can show, in the saved order.
    private var shownWidgets: [ShownWidget] {
        store.layout.widgets.compactMap { placed in
            guard let info = WidgetInfo.resolve(placed.id, metrics: monitor.availableMetrics, mods: mods) else { return nil }
            var widget = ShownWidget(placed: placed, info: info)
            if case .mod(let mod, let modWidget, _) = info.content, let when = modWidget.when, !mod.evaluate(when) {
                guard store.isEditing else { return nil }
                widget.isConditionHidden = true
            }
            return widget
        }
    }
}

/// What the dashboard shows once every widget was removed.
private struct EmptyDashboard: View {
    @Environment(DashboardStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Tile {
            if store.isEditing {
                EmptyState(String(localized: "No widgets"), symbol: "square.grid.2x2",
                           message: String(localized: "Add widgets from the list below."))
            } else {
                EmptyState(String(localized: "No widgets"), symbol: "square.grid.2x2",
                           actionTitle: String(localized: "Edit Widgets")) {
                    withAnimation(Motion.resolve(Motion.gentle, reduceMotion: reduceMotion)) { store.isEditing = true }
                }
            }
        }
    }
}

/// A tile being dragged in edit mode. It floats above the grid at the pointer while the other tiles
/// flow around the place it would drop into.
private struct TileDrag {
    let id: WidgetID
    /// The shown widgets when the drag began, and the columns each wants.
    let order: [WidgetID]
    let spans: [Int]
    let startIndex: Int
    /// Where in the tile it was grabbed.
    let grab: CGSize
    let geometry: GridGeometry
    /// The grid keeps the height of its tallest arrangement while the drag lasts, so the panel does not
    /// change size under the pointer.
    let reservedHeight: CGFloat
    var index: Int
    var isInside = true
    var isSettling = false

    /// The shown widgets in the order the drag would leave them.
    var currentOrder: [WidgetID] {
        var ids = order
        ids.insert(ids.remove(at: startIndex), at: index)
        return ids
    }

    /// Where the tile lands at `index`, in the grid's coordinates.
    func slotFrame(at index: Int) -> CGRect {
        var spans = spans
        spans.insert(spans.remove(at: startIndex), at: index)
        return geometry.frame(of: GridPacking.pack(spans)[index])
    }
}

private struct WidgetGrid: View {
    let widgets: [ShownWidget]
    @Binding var expanded: WidgetID?
    @Binding var selected: WidgetID?

    @Environment(DashboardStore.self) private var store
    @Environment(PanelState.self) private var panel
    @Environment(ModsModel.self) private var mods
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drag: TileDrag?
    /// The floating tile's frame; changed without animation while it follows the pointer.
    @State private var floatingFrame: CGRect = .zero
    /// Frames of the tiles in edit mode, where a drag starts from.
    @State private var frames: [WidgetID: CGRect] = [:]
    @State private var width: CGFloat = 0
    @GestureState private var isDragging = false

    nonisolated private static let space = "widget-grid"

    private var motion: Animation {
        Motion.resolve(Motion.gentle, reduceMotion: reduceMotion)
    }

    var body: some View {
        let ordered = drag.map { drag in drag.currentOrder.compactMap { id in widgets.first { $0.id == id } } } ?? widgets
        let slots = GridPacking.pack(ordered.map(\.size.columns))
        let accessoryID = store.isEditing ? selected : expanded
        let accessoryRow = accessoryID.flatMap { id in ordered.firstIndex { $0.id == id } }.map { slots[$0].row }
        WidgetGridLayout(spacing: Metrics.tileSpacing) {
            ForEach(Array(zip(ordered, slots)), id: \.0.id) { widget, slot in
                cell(widget)
                    .layoutValue(key: GridPlacementKey.self, value: .tile(slot))
            }
            if let accessoryID, let accessoryRow, let widget = ordered.first(where: { $0.id == accessoryID }) {
                accessory(widget)
                    .id(accessoryID)
                    .layoutValue(key: GridPlacementKey.self, value: .accessory(belowRow: accessoryRow))
                    .transition(reduceMotion ? .opacity : .asymmetric(
                        insertion: .scale(scale: 0.9, anchor: .top).combined(with: .opacity),
                        removal: .opacity
                    ))
            }
        }
        .frame(minHeight: drag?.reservedHeight ?? 0, alignment: .top)
        .coordinateSpace(.named(Self.space))
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width = $0 }
        .overlay(alignment: .topLeading) { floatingTile }
        .onChange(of: isDragging) { _, active in
            if !active { cancelDrag() }  // a drag that ended without onEnded, e.g. its tile went away
        }
        .onChange(of: store.isEditing) { drag = nil }
    }

    // MARK: Tiles

    @ViewBuilder
    private func cell(_ widget: ShownWidget) -> some View {
        if store.isEditing {
            editableCell(widget)
        } else {
            let isExpanded = expanded == widget.id
            Tile(tint: isExpanded ? .accentColor : nil, padding: 10, action: { activate(widget) }) {
                WidgetFaceView(widget: widget)
            }
            .accessibilityHint(!widget.hasDetail ? String(localized: "Opens the mod")
                : isExpanded ? String(localized: "Hides details") : String(localized: "Shows details"))
            .accessibilityAddTraits(isExpanded ? .isSelected : [])
            .contextMenu {
                // A mod's widget leads to the mod, and switches it.
                if case .mod(let mod, _, let appearance) = widget.info.content {
                    Button(String(localized: "Open “\(appearance.name)”"), systemImage: "arrow.right.circle") { panel.push(.mod(mod.id)) }
                    if mod.hasSwitch {
                        let isOn = mods.isSwitchedOn(mod)
                        Button(isOn ? String(localized: "Turn Off") : String(localized: "Turn On"), systemImage: "power") {
                            mods.setEnabled(mod, !isOn)
                        }
                        .disabled(mods.requestedSwitch[mod.id] != nil || mod.isSwitching)
                    }
                    Divider()
                }
                Button(String(localized: "Customise"), systemImage: "square.grid.2x2") {
                    withAnimation(motion) { store.isEditing = true }
                }
            }
            .debugAnchor("widget:\(widget.id.rawValue)")
        }
    }

    private func editableCell(_ widget: ShownWidget) -> some View {
        let isSelected = selected == widget.id
        let isDragged = drag?.id == widget.id
        let shape = RoundedRectangle(cornerRadius: Metrics.tileRadius, style: .continuous)
        return WidgetFaceView(widget: widget)
            .environment(\.tileCaptionInset, 14)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .groupSurface(tint: isSelected ? .accentColor : nil)
            .opacity(widget.isConditionHidden ? 0.5 : 1)
            .overlay(alignment: .topTrailing) {
                RemoveBadge(name: widget.info.name) { remove(widget) }
                    .debugAnchor("widget-remove:\(widget.id.rawValue)")
            }
            // While it is dragged, its place shows where it will land.
            .opacity(isDragged ? 0 : 1)
            .overlay {
                if isDragged {
                    shape.strokeBorder(Color.accentColor.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                }
            }
            .contentShape(shape)
            // A press that moves drags the tile; one that does not selects it.
            .gesture(dragGesture(widget).exclusively(before: TapGesture().onEnded { toggleSelection(widget) }))
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named(Self.space)) }) { frames[widget.id] = $0 }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityHint(String(localized: "Shows its options"))
            .accessibilityAction { toggleSelection(widget) }
            .accessibilityAction(named: String(localized: "Move Earlier")) { move(widget, by: -1) }
            .accessibilityAction(named: String(localized: "Move Later")) { move(widget, by: 1) }
            .accessibilityAction(named: String(localized: "Remove")) { remove(widget) }
            .debugAnchor("widget:\(widget.id.rawValue)")
    }

    @ViewBuilder
    private func accessory(_ widget: ShownWidget) -> some View {
        if store.isEditing {
            WidgetOptions(widget: widget) { remove(widget) }
        } else {
            switch widget.info.content {
            case .metric(let metric): MetricDetail(metric: metric, chartStyle: widget.chartStyle, rateUnit: widget.rateUnit)
            case .mod(let mod, let modWidget, _): ModWidgetDetail(mod: mod, widget: modWidget)
            }
        }
    }

    @ViewBuilder
    private var floatingTile: some View {
        if let drag, let widget = widgets.first(where: { $0.id == drag.id }) {
            let shape = RoundedRectangle(cornerRadius: Metrics.tileRadius, style: .continuous)
            WidgetFaceView(widget: widget)
                .padding(10)
                .frame(width: floatingFrame.width, height: floatingFrame.height, alignment: .topLeading)
                .panelGlass(radius: Metrics.tileRadius)
                .groupSurface(tint: nil)
                .clipShape(shape)
                .shadow(color: .black.opacity(drag.isSettling ? 0 : 0.25), radius: 14, y: 8)
                .scaleEffect(drag.isSettling || reduceMotion ? 1 : 1.04)
                .opacity(drag.isInside ? 1 : 0.55)
                .offset(x: floatingFrame.minX, y: floatingFrame.minY)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    // MARK: Actions

    private func activate(_ widget: ShownWidget) {
        guard widget.hasDetail else {
            if case .mod(let mod, _, _) = widget.info.content { panel.push(.mod(mod.id)) }
            return
        }
        withAnimation(motion) {
            expanded = expanded == widget.id ? nil : widget.id
        }
    }

    private func toggleSelection(_ widget: ShownWidget) {
        withAnimation(motion) {
            selected = selected == widget.id ? nil : widget.id
        }
    }

    private func remove(_ widget: ShownWidget) {
        withAnimation(motion) {
            if selected == widget.id { selected = nil }
            store.remove(widget.id)
        }
    }

    /// One place earlier or later among the shown widgets, for assistive technologies.
    private func move(_ widget: ShownWidget, by offset: Int) {
        let shown = widgets.map(\.id)
        guard let index = shown.firstIndex(of: widget.id) else { return }
        withAnimation(motion) {
            store.move(widget.id, toPosition: min(max(index + offset, 0), shown.count - 1), among: shown)
        }
    }

    // MARK: Dragging

    private func dragGesture(_ widget: ShownWidget) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.space))
            .updating($isDragging) { _, active, _ in active = true }
            .onChanged { value in dragChanged(widget, value) }
            .onEnded { _ in dragEnded() }
    }

    private func dragChanged(_ widget: ShownWidget, _ value: DragGesture.Value) {
        if drag == nil {
            guard let frame = frames[widget.id], let start = widgets.firstIndex(where: { $0.id == widget.id }) else { return }
            let spans = widgets.map(\.size.columns)
            let geometry = GridGeometry(width: width, tileHeight: frame.height, spacing: Metrics.tileSpacing)
            // The most rows any drop position would need.
            let rows = spans.indices.map { index in
                var order = spans
                order.insert(order.remove(at: start), at: index)
                return GridPacking.rowCount(GridPacking.pack(order))
            }.max() ?? 0
            drag = TileDrag(id: widget.id, order: widgets.map(\.id), spans: spans, startIndex: start,
                            grab: CGSize(width: value.startLocation.x - frame.minX, height: value.startLocation.y - frame.minY),
                            geometry: geometry, reservedHeight: geometry.height(rows: rows), index: start)
            floatingFrame = frame
            withAnimation(motion) { selected = nil }
        }
        guard var current = drag, !current.isSettling else { return }
        floatingFrame.origin = CGPoint(x: value.location.x - current.grab.width, y: value.location.y - current.grab.height)
        // Leaving the grid, the tile goes back to its place; dropped outside, nothing moves.
        let area = CGRect(x: 0, y: 0, width: width, height: current.reservedHeight).insetBy(dx: -16, dy: -16)
        current.isInside = area.contains(value.location)
        current.index = current.isInside
            ? GridPacking.dropIndex(of: current.startIndex, spans: current.spans, at: value.location, in: current.geometry)
            : current.startIndex
        if current.index != drag?.index || current.isInside != drag?.isInside {
            withAnimation(Motion.resolve(Motion.travel, reduceMotion: reduceMotion)) { drag = current }
        }
    }

    private func dragEnded() {
        guard var current = drag, !current.isSettling else { return }
        if !current.isInside { current.index = current.startIndex }
        current.isSettling = true
        if current.index != current.startIndex {
            store.move(current.id, toPosition: current.index, among: current.order)
        }
        settle(current)
    }

    private func cancelDrag() {
        guard var current = drag, !current.isSettling else { return }
        current.index = current.startIndex
        current.isSettling = true
        settle(current)
    }

    /// The floating tile glides into its slot, then the tile in the grid takes over.
    private func settle(_ current: TileDrag) {
        let animation = Motion.resolve(Motion.travel, reduceMotion: reduceMotion)
        withAnimation(animation) { drag = current }
        withAnimation(animation, completionCriteria: .logicallyComplete) {
            floatingFrame = current.slotFrame(at: current.index)
        } completion: {
            if drag?.isSettling == true { drag = nil }
        }
    }
}

/// The face of any widget's tile.
struct WidgetFaceView: View {
    let widget: ShownWidget

    var body: some View {
        switch widget.info.content {
        case .metric(let metric):
            MetricFace(metric: metric, size: widget.size, chartStyle: widget.chartStyle, rateUnit: widget.rateUnit)
        case .mod(let mod, let modWidget, let appearance):
            ModWidgetFace(mod: mod, widget: modWidget, appearance: appearance, size: widget.size, chartStyle: widget.chartStyle)
        }
    }
}

/// The badge in the corner of a tile in edit mode that takes it off the dashboard.
private struct RemoveBadge: View {
    let name: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "minus.circle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .red)
                .font(.system(size: 15, weight: .semibold))
                .padding(6)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .help(String(localized: "Remove"))
        .accessibilityLabel(String(localized: "Remove “\(name)”"))
    }
}

// MARK: Layout

private nonisolated enum GridPlacement: Equatable {
    case tile(GridSlot)
    /// A detail or the options of a tile, the full width of the grid under its row.
    case accessory(belowRow: Int)
}

private nonisolated struct GridPlacementKey: LayoutValueKey {
    static let defaultValue = GridPlacement.accessory(belowRow: 0)
}

/// Places tiles in the slots `GridPacking` gave them, all rows as tall as the tallest tile, and pushes
/// the rows under an accessory down to make room for it.
private nonisolated struct WidgetGridLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 0  // the page always offers the grid its width
        return CGSize(width: width, height: arrange(width: width, subviews: subviews).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, frame) in zip(subviews, arrange(width: bounds.width, subviews: subviews).frames) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (frames: [CGRect], height: CGFloat) {
        let placements = subviews.map { $0[GridPlacementKey.self] }
        var geometry = GridGeometry(width: width, tileHeight: 0, spacing: spacing)
        var rows = 0
        var accessory: (index: Int, row: Int, height: CGFloat)?
        for (index, placement) in placements.enumerated() {
            switch placement {
            case .tile(let slot):
                let size = subviews[index].sizeThatFits(ProposedViewSize(width: geometry.width(ofSpan: slot.span), height: nil))
                geometry.tileHeight = max(geometry.tileHeight, size.height)
                rows = max(rows, slot.row + 1)
            case .accessory(let row):
                accessory = (index, row, subviews[index].sizeThatFits(ProposedViewSize(width: width, height: nil)).height)
            }
        }
        let extra = accessory.map { $0.height + spacing } ?? 0
        let frames = placements.map { placement -> CGRect in
            switch placement {
            case .tile(let slot):
                let frame = geometry.frame(of: slot)
                return accessory.map { slot.row > $0.row } == true ? frame.offsetBy(dx: 0, dy: extra) : frame
            case .accessory(let row):
                return CGRect(x: 0, y: geometry.height(rows: row + 1) + spacing, width: width, height: accessory?.height ?? 0)
            }
        }
        return (frames, geometry.height(rows: rows) + extra)
    }
}
