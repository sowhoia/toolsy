import SwiftUI

/// A compact fact, a caption over its value: a mod's `stat`. Made to sit in equal columns of a row and
/// readable on a row of its own.
struct StatView: View {
    private let label: String
    private let value: String
    private let icon: String?
    private let tint: Color?

    init(_ label: String, value: String, icon: String? = nil, tint: Color? = nil) {
        self.label = label
        self.value = value
        self.icon = icon
        self.tint = tint
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                if let icon {
                    SymbolImage(icon)
                        .font(.system(size: 11))
                        .foregroundStyle(tint ?? .secondary)
                }
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(value)
                .font(.system(size: 15, weight: .semibold).monospacedDigit())
                .foregroundStyle(tint ?? .primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .truncationMode(.middle)
                // Values tick, often every second: interpolating the glyphs costs several percent of
                // CPU per stat, so a new value simply replaces the old one.
                .contentTransition(.identity)
        }
        .frame(maxWidth: .infinity, minHeight: Metrics.rowMinHeight, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(value)
    }
}
