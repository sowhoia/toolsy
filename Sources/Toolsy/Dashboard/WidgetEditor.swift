import SwiftUI

// The editing tools of the dashboard: the options of the selected widget, the widgets that can be
// added, and the dashboard's own settings.

/// The options of the widget selected in edit mode, under its row.
struct WidgetOptions: View {
    let widget: ShownWidget
    let onRemove: () -> Void
    @Environment(DashboardStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let sizes = [
        PickerOption(value: WidgetSize.small, label: String(localized: "Small")),
        PickerOption(value: WidgetSize.medium, label: String(localized: "Medium")),
        PickerOption(value: WidgetSize.wide, label: String(localized: "Wide")),
    ]
    private static let chartStyles = [
        PickerOption(value: ChartStyle.line, label: String(localized: "Line")),
        PickerOption(value: ChartStyle.area, label: String(localized: "Area")),
        PickerOption(value: ChartStyle.bar, label: String(localized: "Bars")),
    ]
    private static let rateUnits = [
        PickerOption(value: RateUnit.bytes, label: String(localized: "Bytes")),
        PickerOption(value: RateUnit.bits, label: String(localized: "Bits")),
    ]

    var body: some View {
        let id = widget.id
        SectionGroup(widget.info.name) {
            PickerRow(String(localized: "Size"), selection: binding(widget.size) { store.setSize($0, of: id) }, options: Self.sizes)
                .debugAnchor("option-size")
            if widget.info.defaultChartStyle != nil {
                PickerRow(String(localized: "Chart"), selection: binding(widget.chartStyle) { store.setChartStyle($0, of: id) },
                          options: Self.chartStyles)
                    .debugAnchor("option-chart")
            }
            if widget.info.offersRateUnit {
                PickerRow(String(localized: "Speed in"), selection: binding(widget.rateUnit) { store.setRateUnit($0, of: id) },
                          options: Self.rateUnits)
                    .debugAnchor("option-unit")
            }
            GlassButton(String(localized: "Remove from Dashboard"), icon: "minus.circle", kind: .destructive, fillsWidth: true,
                        action: onRemove)
            .debugAnchor("option-remove")
        }
    }

    /// A size change moves tiles to other rows, so it animates; the others redraw in place.
    private func binding<Value>(_ value: Value, set: @escaping (Value) -> Void) -> Binding<Value> {
        Binding(get: { value }, set: { new in
            withAnimation(Motion.resolve(Motion.gentle, reduceMotion: reduceMotion)) { set(new) }
        })
    }
}

/// The widgets that are not on the dashboard, built-in and from mods; a click adds one.
struct WidgetGallery: View {
    @Environment(SystemMonitor.self) private var monitor
    @Environment(DashboardStore.self) private var store
    @Environment(ModsModel.self) private var mods
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let addable = WidgetInfo.available(metrics: monitor.availableMetrics, mods: mods.store.mods).filter { !store.contains($0.id) }
        SectionGroup(String(localized: "Add Widgets"),
                     footer: addable.isEmpty ? String(localized: "Every widget is on the dashboard.") : nil) {
            ForEach(addable) { info in
                GalleryRow(info: info) {
                    withAnimation(Motion.resolve(Motion.gentle, reduceMotion: reduceMotion)) { store.add(info.id) }
                }
                .debugAnchor("gallery:\(info.id.rawValue)")
            }
        }
    }
}

private struct GalleryRow: View {
    let info: WidgetInfo
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                IconBadge(info.symbol, tint: info.tint, size: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(info.name).font(.rowLabel).lineLimit(1)
                    Text(info.source).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "plus.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .green)
                    .font(.system(size: 17))
            }
            .frame(minHeight: Metrics.rowMinHeight)
            .contentShape(.rect)
        }
        .buttonStyle(RowButtonStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Add “\(info.name)”"))
        .accessibilityValue(info.source)
        .accessibilityAddTraits(.isButton)
    }
}

/// The device line switch and the way back to the standard layout.
struct DashboardSettings: View {
    @Environment(DashboardStore.self) private var store
    @Environment(PanelState.self) private var panel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        SectionGroup {
            SwitchRow(String(localized: "Device Info"), icon: "info.circle", isOn: Binding(
                get: { store.layout.showsDeviceLine },
                set: { shows in withAnimation(Motion.resolve(Motion.gentle, reduceMotion: reduceMotion)) { store.setShowsDeviceLine(shows) } }
            ))
            .debugAnchor("device-line")
            GlassButton(String(localized: "Reset to Default…"), icon: "arrow.counterclockwise", fillsWidth: true, action: confirmReset)
                .debugAnchor("reset-dashboard")
        }
    }

    private func confirmReset() {
        panel.confirm(ConfirmationRequest(
            title: String(localized: "Reset the dashboard?"),
            message: String(localized: "Its widgets, their order, sizes and options go back to how they were at first."),
            icon: "square.grid.2x2",
            confirmTitle: String(localized: "Reset"),
            isDestructive: true,
            onConfirm: { [store, reduceMotion] in
                withAnimation(Motion.resolve(Motion.gentle, reduceMotion: reduceMotion)) { store.reset() }
            }
        ))
    }
}
