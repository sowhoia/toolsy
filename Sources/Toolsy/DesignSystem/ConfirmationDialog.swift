import SwiftUI

/// The card of an in-panel confirmation. Present it with `PanelState.confirm(_:)`; the panel
/// dims the page behind it, Return confirms and Esc cancels.
struct ConfirmationDialog: View {
    let request: ConfirmationRequest
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                if let icon = request.icon {
                    IconBadge(icon, tint: request.iconTint, size: 28)
                } else if request.isDestructive {
                    IconBadge("exclamationmark.triangle.fill", tint: .red, size: 28)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(request.title)
                        .font(.system(size: 14, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    if let message = request.message {
                        Text(message)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if let warning = request.warning {
                InlineBanner(warning, kind: .warning)
            }
            if !request.details.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(request.details.enumerated()), id: \.offset) { _, detail in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Circle().fill(.secondary).frame(width: 4, height: 4).alignmentGuide(.firstTextBaseline) { $0[.bottom] + 3 }
                            Text(detail)
                                .font(.system(size: 11, design: .monospaced))
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: Metrics.innerRadius, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                }
            }
            if request.isProgress {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            } else {
                buttons
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelGlass(radius: Metrics.tileRadius)
        .overlay { GlassRim(shape: RoundedRectangle(cornerRadius: Metrics.tileRadius, style: .continuous), intensity: 0.8) }
        .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            if let cancelTitle = request.cancelTitle {
                GlassButton(cancelTitle, fillsWidth: true, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .debugAnchor("dialog-cancel")
            }
            GlassButton(request.confirmTitle, kind: .prominent, tint: request.isDestructive ? .red : .accentColor,
                        fillsWidth: true, action: onConfirm)
                .keyboardShortcut(.defaultAction)
                .debugAnchor("dialog-confirm")
        }
        .padding(.top, 2)
    }
}
