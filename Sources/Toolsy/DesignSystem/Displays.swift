import SwiftUI

/// Text in one of the panel's styles: the `text` control of a mod.
struct StyledText: View {
    private let text: String
    private let style: TextStyle
    private let tint: Color?

    init(_ text: String, style: TextStyle = .body, tint: Color? = nil) {
        self.text = text
        self.style = style
        self.tint = tint
    }

    var body: some View {
        Text(text)
            .font(style.font)
            .foregroundStyle(tint ?? (style == .caption ? Color.secondary : Color.primary))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// An SF Symbol on a tinted rounded square of glass, like the icons in System Settings.
struct IconBadge: View {
    private let symbol: String
    private let tint: Color
    private let size: CGFloat

    init(_ symbol: String, tint: Color = .accentColor, size: CGFloat = Metrics.badgeSize) {
        self.symbol = symbol
        self.tint = tint
        self.size = size
    }

    var body: some View {
        SymbolImage(symbol)
            .symbolRenderingMode(.monochrome)
            .font(.system(size: size * 0.5, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background {
                let shape = RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                shape.fill(tint)
                shape.fill(LinearGradient(colors: [.white.opacity(0.24), .white.opacity(0)], startPoint: .top, endPoint: .center))
                GlassRim(shape: shape, intensity: 0.7, lineWidth: 0.75)
            }
            .accessibilityHidden(true)
    }
}

/// A "label: value" line: the `value` control of a mod. With `copyable` a click copies the
/// value and the row confirms it briefly.
struct ValueRow: View {
    private let label: String
    private let value: String
    private let icon: String?
    private let tint: Color?
    private let copyable: Bool

    init(_ label: String, value: String, icon: String? = nil, tint: Color? = nil, copyable: Bool = false) {
        self.label = label
        self.value = value
        self.icon = icon
        self.tint = tint
        self.copyable = copyable
    }

    @State private var copied = CopyFeedback()
    @State private var isHovered = false

    var body: some View {
        if copyable {
            Button { copied.copy(value) } label: { content }
                .buttonStyle(.plain)
                .onHover { isHovered = $0 }
                .help(String(localized: "Click to copy"))
                .accessibilityHint(String(localized: "Copies the value"))
        } else {
            content
        }
    }

    private var content: some View {
        HStack(spacing: 8) {
            ControlLabel(label, icon: icon)
            Spacer(minLength: 12)
            ZStack(alignment: .trailing) {
                Text(value)
                    .font(.rowValue)
                    .foregroundStyle(tint ?? .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .opacity(copied.isShowing ? 0 : 1)
                if copied.isShowing {
                    Label(String(localized: "Copied"), systemImage: "checkmark")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.green)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            if copyable {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .opacity(isHovered && !copied.isShowing ? 1 : 0)
            }
        }
        .frame(minHeight: Metrics.rowMinHeight)
        .contentShape(.rect)
        .animation(Motion.snappy, value: copied.isShowing)
        .animation(Motion.fade, value: isHovered)
        .accessibilityElement(children: .combine)
    }
}

/// A row of a list: the rows of a mod's `list` control. With `action` the row is clickable.
struct ListRow: View {
    private let title: String
    private let subtitle: String?
    private let value: String?
    private let icon: String?
    private let tint: Color?
    private let action: (() -> Void)?

    init(_ title: String, subtitle: String? = nil, value: String? = nil, icon: String? = nil,
         tint: Color? = nil, action: (() -> Void)? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.value = value
        self.icon = icon
        self.tint = tint
        self.action = action
    }

    var body: some View {
        if let action {
            Button(action: action) { content(showsChevron: true) }
                .buttonStyle(RowButtonStyle())
        } else {
            content(showsChevron: false)
        }
    }

    private func content(showsChevron: Bool) -> some View {
        HStack(spacing: 10) {
            if let icon {
                IconBadge(icon, tint: tint ?? .gray, size: 24)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.rowLabel).lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let value, !value.isEmpty {
                Text(value)
                    .font(.rowValue)
                    .foregroundStyle(icon == nil ? (tint ?? .secondary) : .secondary)
                    .lineLimit(1)
            }
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(minHeight: Metrics.rowMinHeight)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

/// Highlight for clickable rows inside a section: a soft rounded fill that reaches a little
/// past the row, the way a menu highlights its items.
struct RowButtonStyle: ButtonStyle {
    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(isEnabled ? 1 : 0.45)
            .background {
                RoundedRectangle(cornerRadius: Metrics.innerRadius, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.1 : isHovered && isEnabled ? 0.055 : 0))
                    .padding(.horizontal, -8)
                    .padding(.vertical, -4)
            }
            .contentShape(.focusEffect, .rect(cornerRadius: Metrics.innerRadius))
            .animation(Motion.fade, value: isHovered)
            .onHover { isHovered = $0 }
    }
}

/// A coloured dot and a short status text (a mod's `status` and `level`).
struct StatusLabel: View {
    private let text: String
    private let level: StatusLevel

    init(_ text: String, level: StatusLevel) {
        self.text = text
        self.level = level
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(level.color)
                .frame(width: 7, height: 7)
                .overlay { Circle().strokeBorder(Color.primary.opacity(level == .off ? 0.3 : 0), lineWidth: 1) }
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .animation(Motion.fade, value: level)
    }
}

/// An inline warning or error with an optional dismiss button.
struct InlineBanner: View {
    enum Kind: Sendable { case warning, error }

    private let message: String
    private let kind: Kind
    private let action: Action?
    private let onDismiss: (() -> Void)?

    /// A button under the message that resolves the problem, e.g. "Update…".
    struct Action {
        var title: String
        var isBusy = false
        var perform: () -> Void
    }

    init(_ message: String, kind: Kind = .error, action: Action? = nil, onDismiss: (() -> Void)? = nil) {
        self.message = message
        self.kind = kind
        self.action = action
        self.onDismiss = onDismiss
    }

    private var color: Color { kind == .error ? .red : .orange }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: kind == .error ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 8) {
                Text(message)
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let action {
                    GlassButton(action.title, kind: .prominent, tint: color, isBusy: action.isBusy, action: action.perform)
                        .debugAnchor("banner-action")
                }
            }
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(RowButtonStyle())
                .foregroundStyle(.secondary)
                .accessibilityLabel(String(localized: "Dismiss"))
            }
        }
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: Metrics.innerRadius + 2, style: .continuous)
                .fill(color.opacity(0.14))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(kind == .error ? String(localized: "Error") : String(localized: "Warning"))
    }
}

/// A placeholder for a list with nothing in it.
struct EmptyState: View {
    private let symbol: String
    private let title: String
    private let message: String?
    private let actionTitle: String?
    private let action: (() -> Void)?

    init(_ title: String, symbol: String, message: String? = nil, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.symbol = symbol
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }

    var body: some View {
        VStack(spacing: 6) {
            SymbolImage(symbol)
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let actionTitle, let action {
                GlassButton(actionTitle, action: action)
                    .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .accessibilityElement(children: action == nil ? .combine : .contain)
    }
}
