import SwiftUI

/// One choice of a picker (a mod's picker option).
struct PickerOption<Value: Hashable>: Identifiable {
    var value: Value
    var label: String
    var icon: String?

    var id: Value { value }
}

/// The iOS 26 segmented control: the selected segment rests on a raised piece of glass; when another
/// segment is chosen the selection lifts into a lens of clear glass that magnifies the labels it
/// passes over, travels and settles. The selection can also be dragged. Arrow keys move it when the
/// control has keyboard focus.
struct SegmentedPicker<Value: Hashable>: View {
    @Binding private var selection: Value
    private let options: [PickerOption<Value>]
    private let label: String

    init(selection: Binding<Value>, options: [PickerOption<Value>], label: String) {
        _selection = selection
        self.options = options
        self.label = label
    }

    private static var height: CGFloat { 28 }
    private static var padding: CGFloat { 2 }
    /// How far the lens reaches past the selected segment on each side.
    private static var lensGrowth: CGSize { CGSize(width: 5, height: 4) }

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var width: CGFloat = 0
    @State private var hovered: Int?
    @State private var isLifted = false
    /// The centre of the selection while it is dragged; nil while it rests on its segment.
    @State private var dragX: CGFloat?
    /// Whether the current press started on the selection, which can then be dragged.
    @State private var grabbedSelection = false
    @State private var isPressed = false
    @GestureState private var gestureIsActive = false
    @State private var stretch: CGFloat = 0
    @State private var settling: Task<Void, Never>?

    /// Nil when the bound value is none of the options (a mod's state may hold anything).
    private var selectedIndex: Int? { options.firstIndex { $0.value == selection } }
    private var segmentWidth: CGFloat { max(0, (width - 2 * Self.padding) / CGFloat(max(options.count, 1))) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Capsule().fill(Color.primary.opacity(0.08))
            if let hovered, hovered != selectedIndex, !isPressed {
                Capsule()
                    .fill(Color.primary.opacity(0.06))
                    .frame(width: segmentWidth, height: Self.height - 2 * Self.padding)
                    .offset(x: segmentFrame(hovered).minX, y: Self.padding)
                    .transition(.opacity)
            }
            // At rest the selection is a raised piece of glass under its label.
            if let selectedIndex {
                GlassChip(shape: Capsule())
                    .frame(width: segmentWidth, height: Self.height - 2 * Self.padding)
                    .offset(x: segmentFrame(selectedIndex).minX, y: Self.padding)
                    .opacity(isLifted ? 0 : 1)
            }
            LensedScene(lens: lensFrame, lift: isLifted ? 1 : 0, magnification: 1.16) {
                labels
            }
        }
        .frame(height: Self.height)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width = $0 }
        .contentShape(.capsule)
        .gesture(gesture, isEnabled: isEnabled)
        .onContinuousHover { phase in
            switch phase {
            case .active(let point): hovered = index(at: point.x)
            case .ended: hovered = nil
            }
        }
        .opacity(isEnabled ? 1 : 0.45)
        .animation(Motion.resolve(Motion.travel, reduceMotion: reduceMotion), value: selection)
        .animation(Motion.fade, value: hovered)
        .onChange(of: gestureIsActive) { _, active in
            if !active, isPressed {
                isPressed = false
                travel(to: selectedIndex)
            }
        }
        .onDisappear {
            // Comes back at rest, whatever it was doing when it went away.
            settling?.cancel()
            isPressed = false
            isLifted = false
            dragX = nil
            stretch = 0
        }
        .focusable(isEnabled, interactions: .activate)
        .contentShape(.focusEffect, .capsule)
        .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
            let forward = press.key == .rightArrow
            let current = selectedIndex ?? (forward ? -1 : options.count)
            travel(to: min(max(current + (forward ? 1 : -1), 0), options.count - 1))
            return .handled
        }
        .accessibilityRepresentation {
            Picker(label, selection: $selection) {
                ForEach(options) { Text($0.label).tag($0.value) }
            }
            .pickerStyle(.segmented)
        }
    }

    private var labels: some View {
        HStack(spacing: 0) {
            ForEach(options) { option in
                HStack(spacing: 4) {
                    if let icon = option.icon { SymbolImage(icon) }
                    Text(option.label).lineLimit(1).minimumScaleFactor(0.85)
                }
                .font(.system(size: 12, weight: option.value == selection ? .semibold : .regular))
                .foregroundStyle(.primary)
                .padding(.horizontal, 6)
                .frame(width: segmentWidth, height: Self.height)
            }
        }
        .padding(.horizontal, Self.padding)
    }

    private func segmentFrame(_ index: Int) -> CGRect {
        CGRect(x: Self.padding + CGFloat(index) * segmentWidth, y: Self.padding,
               width: segmentWidth, height: Self.height - 2 * Self.padding)
    }

    /// Resting, the lens is the selected segment; lifted, it is larger, follows a drag and stretches.
    private var lensFrame: CGRect {
        let rest = segmentFrame(selectedIndex ?? 0)
        guard isLifted else { return rest }
        let centre = dragX ?? rest.midX
        let width = (rest.width + 2 * Self.lensGrowth.width) * (1 + stretch)
        let height = (rest.height + 2 * Self.lensGrowth.height) * (1 - 0.3 * stretch)
        return CGRect(x: centre - width / 2, y: rest.midY - height / 2, width: width, height: height)
    }

    private func index(at x: CGFloat) -> Int {
        guard segmentWidth > 0 else { return selectedIndex ?? 0 }
        return min(max(Int((x - Self.padding) / segmentWidth), 0), options.count - 1)
    }

    private var gesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($gestureIsActive) { _, active, _ in active = true }
            .onChanged { value in
                if !isPressed {
                    isPressed = true
                    settling?.cancel()
                    grabbedSelection = selectedIndex != nil && index(at: value.startLocation.x) == selectedIndex
                    if grabbedSelection, !reduceMotion {
                        withAnimation(Motion.liquid) { isLifted = true }
                    }
                }
                guard grabbedSelection, !reduceMotion, abs(value.translation.width) > 2 || dragX != nil else { return }
                let half = segmentWidth / 2
                withAnimation(.interactiveSpring(response: 0.18, dampingFraction: 0.86)) {
                    dragX = min(max(value.location.x, Self.padding + half), width - Self.padding - half)
                    stretch = min(abs(value.velocity.width) / 2400, 0.2)
                }
            }
            .onEnded { value in
                guard isPressed else { return }
                isPressed = false
                travel(to: index(at: dragX ?? value.location.x))
            }
    }

    /// Moves the selection to `index`: it lifts, travels (stretching on the way) and settles. Without a
    /// selection there is nothing to lift; the new one just appears.
    private func travel(to index: Int?) {
        guard let index else { return }
        let moves = index != selectedIndex || dragX != nil
        if moves, selectedIndex != nil, !reduceMotion {
            settling?.cancel()
            withAnimation(Motion.liquid) { isLifted = true }
            if index != selectedIndex {
                withAnimation(.easeOut(duration: 0.12)) { stretch = 0.14 }
            }
        }
        withAnimation(Motion.resolve(Motion.travel, reduceMotion: reduceMotion)) {
            dragX = nil
            if index != selectedIndex { selection = options[index].value }
        }
        settling?.cancel()
        settling = Task {
            do { try await Task.sleep(for: .milliseconds(moves ? 200 : 40)) } catch { return }  // a newer press took over
            withAnimation(Motion.liquid) {
                isLifted = false
                stretch = 0
            }
        }
    }
}

/// A pop-up menu of options shown as a glass capsule with the current choice.
struct MenuPicker<Value: Hashable>: View {
    @Binding private var selection: Value
    private let options: [PickerOption<Value>]
    private let label: String
    private let fillsWidth: Bool

    /// `fillsWidth` stretches the capsule across the width it is offered, as in a row of a card's quick controls.
    init(selection: Binding<Value>, options: [PickerOption<Value>], label: String, fillsWidth: Bool = false) {
        _selection = selection
        self.options = options
        self.label = label
        self.fillsWidth = fillsWidth
    }

    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled

    private var current: PickerOption<Value>? {
        options.first { $0.value == selection }
    }

    var body: some View {
        Menu {
            Picker(label, selection: $selection) {
                ForEach(options) { option in
                    if let icon = option.icon {
                        Label(option.label, systemImage: icon).tag(option.value)
                    } else {
                        Text(option.label).tag(option.value)
                    }
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            // Where the capsule is narrow (a row of quick controls), the choice keeps its words and drops its icon.
            ViewThatFits(in: .horizontal) {
                choice(showsIcon: true)
                choice(showsIcon: false)
            }
            .font(.system(size: 13))
            .frame(maxWidth: fillsWidth ? .infinity : nil)
            .padding(.horizontal, 12)
            .frame(height: Metrics.controlHeight)
            .background { GlassChip(shape: Capsule(), isHovered: isHovered && isEnabled) }
            .contentShape(.capsule)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: !fillsWidth, vertical: true)
        .opacity(isEnabled ? 1 : 0.45)
        .onHover { isHovered = $0 }
        .animation(Motion.fade, value: isHovered)
        .accessibilityLabel(label)
        .accessibilityValue(current?.label ?? "")
    }

    private func choice(showsIcon: Bool) -> some View {
        HStack(spacing: 6) {
            if showsIcon, let icon = current?.icon { SymbolImage(icon) }
            Text(current?.label ?? "—").lineLimit(1)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }
}

/// How a picker row presents its options; `automatic` is segmented up to four options.
enum PickerPresentation: String, Sendable {
    case automatic, segmented, menu
}

/// A picker with its label: the `picker` control of a mod.
struct PickerRow<Value: Hashable>: View {
    private let label: String?
    private let icon: String?
    @Binding private var selection: Value
    private let options: [PickerOption<Value>]
    private let presentation: PickerPresentation

    init(_ label: String? = nil, icon: String? = nil, selection: Binding<Value>, options: [PickerOption<Value>],
         presentation: PickerPresentation = .automatic) {
        self.label = label
        self.icon = icon
        _selection = selection
        self.options = options
        self.presentation = presentation
    }

    private var isSegmented: Bool {
        switch presentation {
        case .automatic: options.count <= 4
        case .segmented: true
        case .menu: false
        }
    }

    var body: some View {
        if isSegmented {
            VStack(alignment: .leading, spacing: 6) {
                if let label { ControlLabel(label, icon: icon) }
                if options.isEmpty {
                    NoOptions(label: label)
                        .frame(maxWidth: .infinity)
                        .frame(height: Metrics.controlHeight)
                        .background { Capsule().fill(Color.primary.opacity(0.08)) }
                } else {
                    SegmentedPicker(selection: $selection, options: options, label: label ?? "")
                }
            }
        } else {
            HStack(spacing: 8) {
                if let label { ControlLabel(label, icon: icon) }
                Spacer(minLength: 8)
                if options.isEmpty {
                    NoOptions(label: label)
                        .padding(.horizontal, 12)
                        .frame(height: Metrics.controlHeight)
                        .background { Capsule().fill(Color.primary.opacity(0.08)) }
                } else {
                    MenuPicker(selection: $selection, options: options, label: label ?? "")
                }
            }
            .frame(minHeight: Metrics.rowMinHeight)
        }
    }
}

/// What a picker shows in place of its choices while it has none (a mod's `optionsFrom` list that is
/// empty or not there yet): plainly nothing to choose, and nothing to press.
private struct NoOptions: View {
    let label: String?

    var body: some View {
        Text("No options")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label ?? "")
            .accessibilityValue(String(localized: "No options"))
    }
}

/// A single-line text field that reports its text when committed with Return or by leaving
/// the field: the `input` control of a mod.
struct TextFieldRow: View {
    private let label: String?
    private let icon: String?
    private let placeholder: String
    private let value: String
    private let onCommit: (String) -> Void

    init(_ label: String? = nil, icon: String? = nil, placeholder: String = "", value: String,
         onCommit: @escaping (String) -> Void) {
        self.label = label
        self.icon = icon
        self.placeholder = placeholder
        self.value = value
        self.onCommit = onCommit
    }

    @State private var draft: String?
    @FocusState private var isFocused: Bool
    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: 10) {
            if let label {
                ControlLabel(label, icon: icon)
                    .layoutPriority(1)
            }
            TextField(placeholder, text: Binding(get: { draft ?? value }, set: { draft = $0 }))
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($isFocused)
                .onSubmit(commit)
                .padding(.horizontal, 10)
                .frame(height: Metrics.controlHeight)
                .background {
                    // A field is a well in the glass, where buttons are raised pieces of it.
                    RoundedRectangle(cornerRadius: Metrics.innerRadius, style: .continuous)
                        .fill(Color.primary.opacity(isFocused ? 0.05 : isHovered ? 0.08 : 0.06)
                            .shadow(.inner(color: .black.opacity(0.14), radius: 1.2, y: 0.8)))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: Metrics.innerRadius, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(isFocused ? 0.9 : 0), lineWidth: 1.5)
                }
                .onHover { isHovered = $0 }
                .opacity(isEnabled ? 1 : 0.45)
                .accessibilityLabel(label ?? placeholder)
        }
        .animation(Motion.fade, value: isFocused)
        .onChange(of: isFocused) { _, focused in
            if !focused { commit() }
        }
        // Closing the panel or leaving the page while typing keeps what was typed.
        .onDisappear(perform: commit)
    }

    private func commit() {
        guard let draft else { return }
        self.draft = nil
        if draft != value { onCommit(draft) }
    }
}
