import SwiftUI

/// Rows of one height that the user drags into another order. A row that is pressed and moved lifts onto a piece of
/// glass and follows the pointer while the rows it passes make room; on release it settles into its new place and
/// `onMove` gets its id and new index. Hairlines between the rows stay where rows meet. VoiceOver moves a row with
/// the actions Move Up and Move Down.
struct ReorderableRows<Item: Identifiable, Row: View>: View {
    private let items: [Item]
    private let rowHeight: CGFloat
    private let onMove: (Item.ID, Int) -> Void
    private let row: (Item) -> Row

    init(_ items: [Item], rowHeight: CGFloat, onMove: @escaping (Item.ID, Int) -> Void, @ViewBuilder row: @escaping (Item) -> Row) {
        self.items = items
        self.rowHeight = rowHeight
        self.onMove = onMove
        self.row = row
    }

    private struct Drag: Equatable {
        var id: Item.ID
        var start: Int
        var translation: CGFloat
    }

    @State private var drag: Drag?
    @GestureState private var isDragging = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    nonisolated private static var space: String { "reorderable-rows" }

    private var motion: Animation {
        Motion.resolve(Motion.travel, reduceMotion: reduceMotion)
    }

    /// Where the dragged row would land now.
    private var target: Int? {
        guard let drag, !items.isEmpty else { return nil }
        return RowReordering.target(start: drag.start, translation: drag.translation, rowHeight: rowHeight, count: items.count)
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                let isDragged = drag?.id == item.id
                row(item)
                    .frame(height: rowHeight)
                    .background {
                        if isDragged {
                            LiftedRow()
                                .padding(.horizontal, -8)
                                .transition(.opacity)
                        }
                    }
                    .scaleEffect(isDragged && !reduceMotion ? 1.02 : 1)
                    .offset(y: offset(of: index, isDragged: isDragged))
                    // The rows that make room glide; the dragged one is where the pointer is.
                    .animation(isDragged ? nil : motion, value: target)
                    .zIndex(isDragged ? 1 : 0)
                    .gesture(dragGesture(item, at: index))
                    // The row is one group in VoiceOver, which carries the moves.
                    .accessibilityElement(children: .contain)
                    .accessibilityAction(named: String(localized: "Move Up")) { move(item, from: index, to: index - 1) }
                    .accessibilityAction(named: String(localized: "Move Down")) { move(item, from: index, to: index + 1) }
            }
        }
        .coordinateSpace(.named(Self.space))
        .background(alignment: .top) {
            if items.count > 1 {
                ZStack(alignment: .top) {
                    ForEach(1..<items.count, id: \.self) { line in
                        Hairline().offset(y: CGFloat(line) * rowHeight)
                    }
                }
                .allowsHitTesting(false)
            }
        }
        .onChange(of: isDragging) { _, active in
            // A drag that ended without `onEnded` (its row went away): everything goes back.
            if !active, drag != nil { withAnimation(motion) { drag = nil } }
        }
        .onChange(of: items.map(\.id)) {
            // Rows came or went under the drag, so the place it started from means another row now: it ends unmoved.
            if drag != nil { withAnimation(motion) { drag = nil } }
        }
    }

    private func offset(of index: Int, isDragged: Bool) -> CGFloat {
        guard let drag, let target else { return 0 }
        return isDragged ? drag.translation : RowReordering.shift(of: index, start: drag.start, target: target, rowHeight: rowHeight)
    }

    private func dragGesture(_ item: Item, at index: Int) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.space))
            .updating($isDragging) { _, active, _ in active = true }
            .onChanged { value in
                if drag == nil {
                    withAnimation(Motion.snappy) { drag = Drag(id: item.id, start: index, translation: 0) }
                }
                drag?.translation = value.translation.height
            }
            .onEnded { _ in
                guard let drag, let target else { return }
                withAnimation(motion) {
                    if target != drag.start { onMove(drag.id, target) }
                    self.drag = nil
                }
            }
    }

    private func move(_ item: Item, from index: Int, to destination: Int) {
        guard items.indices.contains(destination), destination != index else { return }
        withAnimation(motion) { onMove(item.id, destination) }
    }
}

/// Where a dragged row lands and how far the rows it passes step aside, for rows of one height.
nonisolated enum RowReordering {
    /// The index the row dragged from `start` by `translation` lands at, among `count` rows: the nearest row
    /// boundary, kept within the list.
    static func target(start: Int, translation: CGFloat, rowHeight: CGFloat, count: Int) -> Int {
        guard rowHeight > 0, count > 0 else { return start }
        return min(max(start + Int((translation / rowHeight).rounded()), 0), count - 1)
    }

    /// How far the row at `index` steps aside while the row dragged from `start` is over `target`: a row height
    /// towards where the dragged row came from, for the rows between.
    static func shift(of index: Int, start: Int, target: Int, rowHeight: CGFloat) -> CGFloat {
        if start < target, index > start, index <= target { return -rowHeight }
        if start > target, index >= target, index < start { return rowHeight }
        return 0
    }
}

/// The piece of glass under a dragged row: it blurs the rows it passes over, as the dashboard's dragged tile does.
private struct LiftedRow: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.innerRadius + 2, style: .continuous)
        Color.clear
            .panelGlass(radius: Metrics.innerRadius + 2)
            .background { shape.fill(Color.white.opacity(colorScheme == .dark ? 0.06 : 0.35)) }
            .overlay { GlassRim(shape: shape, intensity: 0.8) }
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.35 : 0.16), radius: 10, y: 5)
    }
}
