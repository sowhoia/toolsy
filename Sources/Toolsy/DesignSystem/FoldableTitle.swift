import SwiftUI

/// The title of a group the user can fold: a button across the group's width with a chevron that
/// turns as the group folds and unfolds. Click it, press it from the keyboard, or use VoiceOver's
/// default action.
struct FoldableTitle: View {
    private let title: String
    @Binding private var isExpanded: Bool

    init(_ title: String, isExpanded: Binding<Bool>) {
        self.title = title
        _isExpanded = isExpanded
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        Button {
            withAnimation(Motion.resolve(Motion.gentle, reduceMotion: reduceMotion)) { isExpanded.toggle() }
        } label: {
            HStack(spacing: 8) {
                Text(title)
                    .font(.tileTitle)
                    .foregroundStyle(isHovered ? .primary : .secondary)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isHovered ? .secondary : .tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            // A row's height to aim at, though the title is one line of small text.
            .frame(minHeight: Metrics.rowMinHeight)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(Motion.fade, value: isHovered)
        .accessibilityAddTraits(.isHeader)
        .accessibilityValue(isExpanded ? String(localized: "Expanded") : String(localized: "Collapsed"))
        .accessibilityHint(isExpanded ? String(localized: "Folds the section") : String(localized: "Unfolds the section"))
        .debugAnchor("fold:\(title)")
    }
}
