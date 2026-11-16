import AppKit
import SwiftUI

/// The iOS 26 Liquid Glass switch: a capsule track and a capsule thumb, wider than tall, that lifts
/// into a lens of clear glass while it is held or travels, stretches as it is dragged and settles
/// back with a little bounce. Click or drag it; Space toggles it when it has keyboard focus.
///
/// `isBusy` is for switches whose action takes seconds: the thumb shows a spinner at the
/// requested position and the switch ignores input until the caller clears it.
struct GlassSwitch: View {
    @Binding private var isOn: Bool
    private let isBusy: Bool
    private let tint: Color
    private let label: String

    init(isOn: Binding<Bool>, isBusy: Bool = false, tint: Color = .green, label: String) {
        _isOn = isOn
        self.isBusy = isBusy
        self.tint = tint
        self.label = label
    }

    static let trackSize = CGSize(width: 54, height: 24)
    private static let thumbSize = CGSize(width: 32, height: 20)
    private static let inset: CGFloat = 2
    private static let travel = trackSize.width - thumbSize.width - 2 * inset
    /// How far the lens reaches past the resting thumb on each side: well past the track, so the
    /// track is seen running through the clear glass.
    private static let lensGrowth = CGSize(width: 8, height: 8)

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var isPressed = false
    /// True while the drag gesture runs; unlike `isPressed` it also resets when the gesture is cancelled.
    @GestureState private var gestureIsActive = false
    @State private var isLifted = false
    @State private var isHovered = false
    /// Thumb position while dragging, 0...travel; nil when it rests at its value.
    @State private var dragPosition: CGFloat?
    @State private var dragStartPosition: CGFloat = 0
    /// How much wider the lens is from the speed of a drag or a toggle; it flattens as it widens.
    @State private var stretch: CGFloat = 0
    @State private var settling: Task<Void, Never>?

    private var interactive: Bool { isEnabled && !isBusy }
    private var position: CGFloat { dragPosition ?? (isOn ? Self.travel : 0) }

    var body: some View {
        LensedScene(lens: thumbFrame, lift: isLifted ? 1 : 0, magnification: 1.1, knob: true, isBusy: isBusy) {
            ZStack {
                Capsule().fill(Color.primary.opacity(contrast == .increased ? 0.28 : 0.16))
                Capsule().fill(tint).opacity(Self.tintAmount(at: position / Self.travel))
                if contrast == .increased {
                    Capsule().strokeBorder(Color.primary.opacity(0.5), lineWidth: 1)
                }
            }
            .frame(width: Self.trackSize.width, height: Self.trackSize.height)
        }
        .frame(width: Self.trackSize.width, height: Self.trackSize.height)
        .brightness(isHovered && interactive ? 0.04 : 0)
        .opacity(isEnabled ? 1 : 0.4)
        .saturation(isBusy ? 0.6 : 1)
        .contentShape(.capsule)
        .gesture(dragGesture, isEnabled: interactive)
        .onHover { isHovered = $0 }
        .focusable(interactive, interactions: .activate)
        .contentShape(.focusEffect, .capsule)
        .onKeyPress(.space) {
            guard interactive else { return .ignored }
            toggle()
            return .handled
        }
        .animation(Motion.resolve(Motion.travel, reduceMotion: reduceMotion), value: isOn)
        .animation(Motion.fade, value: isHovered)
        .animation(Motion.fade, value: isBusy)
        .onChange(of: gestureIsActive) { _, active in
            // A press that ends without `onEnded` was cancelled (the switch turned busy, the panel
            // closed): put the thumb back.
            if !active, isPressed {
                isPressed = false
                travel(to: isOn)
            }
        }
        .onDisappear {
            // Comes back at rest, whatever it was doing when it went away.
            settling?.cancel()
            isPressed = false
            isLifted = false
            dragPosition = nil
            stretch = 0
        }
        .accessibilityRepresentation {
            Toggle(label, isOn: Binding(get: { isOn }, set: { if $0 != isOn { toggle() } }))
                .disabled(!interactive)
        }
        .accessibilityValue(isBusy ? String(localized: "In progress") : "")
    }

    /// The track turns to the tint over the middle of the travel, so a slow drag is never a long
    /// grey-green mix.
    private static func tintAmount(at progress: CGFloat) -> CGFloat {
        let t = min(max((progress - 0.2) / 0.6, 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// At rest the thumb sits inside the track; lifted, it is the lens around that place, stretched.
    private var thumbFrame: CGRect {
        let rest = CGRect(x: Self.inset + position, y: Self.inset, width: Self.thumbSize.width, height: Self.thumbSize.height)
        guard isLifted else { return rest }
        let width = (rest.width + 2 * Self.lensGrowth.width) * (1 + stretch)
        let height = (rest.height + 2 * Self.lensGrowth.height) * (1 - 0.4 * stretch)
        return CGRect(x: rest.midX - width / 2, y: rest.midY - height / 2, width: width, height: height)
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($gestureIsActive) { _, active, _ in active = true }
            .onChanged { value in
                if !isPressed {
                    isPressed = true
                    settling?.cancel()
                    dragStartPosition = position
                    if !reduceMotion {
                        withAnimation(Motion.liquid) { isLifted = true }
                    }
                }
                // Short movements count as a click, so the lens does not jitter under the pointer.
                guard abs(value.translation.width) > 2 || dragPosition != nil else { return }
                let newPosition = min(max(dragStartPosition + value.translation.width, 0), Self.travel)
                if let old = dragPosition, (old < Self.travel / 2) != (newPosition < Self.travel / 2) {
                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                }
                withAnimation(.interactiveSpring(response: 0.18, dampingFraction: 0.86)) {
                    dragPosition = newPosition
                    stretch = reduceMotion ? 0 : min(abs(value.velocity.width) / 2400, 0.22)
                }
            }
            .onEnded { value in
                guard isPressed else { return }
                isPressed = false
                let target: Bool
                if let dragPosition {
                    // A flick decides by direction; a slow drag by where the thumb was let go.
                    let flick = value.predictedEndTranslation.width - value.translation.width
                    target = abs(flick) > 12 ? flick > 0 : dragPosition > Self.travel / 2
                } else {
                    target = !isOn
                }
                travel(to: target)
            }
    }

    /// Space and the accessibility action: the thumb lifts, travels and settles, as for a click.
    private func toggle() {
        if !reduceMotion {
            settling?.cancel()
            withAnimation(Motion.liquid) { isLifted = true }
        }
        travel(to: !isOn)
    }

    /// Sends the thumb to `target` and lets the lens settle back into the thumb once it has nearly
    /// arrived; a lens with a way to go stretches on it.
    private func travel(to target: Bool) {
        let moves = abs((target ? Self.travel : 0) - position) > 2
        withAnimation(Motion.resolve(Motion.travel, reduceMotion: reduceMotion)) { dragPosition = nil }
        if moves, isLifted {
            withAnimation(.easeOut(duration: 0.12)) { stretch = 0.16 }
        }
        set(target)
        settling?.cancel()
        settling = Task {
            do { try await Task.sleep(for: .milliseconds(moves ? 190 : 40)) } catch { return }  // a newer press took over
            withAnimation(Motion.liquid) {
                isLifted = false
                stretch = 0
            }
        }
    }

    private func set(_ value: Bool) {
        guard value != isOn else { return }
        isOn = value
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }
}

/// A switch with its label: the `toggle` control of a mod, and a settings row.
struct SwitchRow: View {
    private let label: String
    private let icon: String?
    @Binding private var isOn: Bool
    private let isBusy: Bool
    private let tint: Color

    init(_ label: String, icon: String? = nil, isOn: Binding<Bool>, isBusy: Bool = false, tint: Color = .green) {
        self.label = label
        self.icon = icon
        _isOn = isOn
        self.isBusy = isBusy
        self.tint = tint
    }

    var body: some View {
        HStack(spacing: 10) {
            ControlLabel(label, icon: icon)
            Spacer(minLength: 8)
            GlassSwitch(isOn: $isOn, isBusy: isBusy, tint: tint, label: label)
        }
        .frame(minHeight: Metrics.rowMinHeight)
    }
}

/// Icon and label at the leading edge of a control row.
struct ControlLabel: View {
    private let text: String
    private let icon: String?
    private let tint: Color?
    @Environment(\.isEnabled) private var isEnabled

    init(_ text: String, icon: String? = nil, tint: Color? = nil) {
        self.text = text
        self.icon = icon
        self.tint = tint
    }

    var body: some View {
        HStack(spacing: 8) {
            if let icon {
                SymbolImage(icon)
                    .font(.system(size: 13))
                    .foregroundStyle(tint ?? .secondary)
                    .frame(width: 18)
            }
            Text(text)
                .font(.rowLabel)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .opacity(isEnabled ? 1 : 0.5)
    }
}
