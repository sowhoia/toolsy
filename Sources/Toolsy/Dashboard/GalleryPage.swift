#if DEBUG
import SwiftUI

/// Every component of the design system in each of its states, for design review and
/// screenshots. Debug builds only; reached from Settings or with `--page gallery`.
struct GalleryPage: View {
    @Environment(PanelState.self) private var panel

    @State private var switches = [true, false, true]
    @State private var busySwitch = true
    @State private var volume = 64.0
    @State private var steps = 3.0
    @State private var count = 2.0
    @State private var mode = "auto"
    @State private var region = "eu"
    @State private var host = "example.com"
    @State private var showsBanner = true
    @State private var samples = GalleryPage.seed(60, base: 40)
    @State private var secondSamples = GalleryPage.seed(60, base: 20)
    @State private var bars = GalleryPage.seed(24, base: 50)
    @State private var arranged = [
        GalleryRow(name: String(localized: "Morning"), symbol: "sun.max.fill", tint: .orange),
        GalleryRow(name: String(localized: "Focus"), symbol: "moon.fill", tint: .indigo),
        GalleryRow(name: String(localized: "Travel"), symbol: "airplane", tint: .teal),
    ]

    private let modes = [
        PickerOption(value: "auto", label: String(localized: "Auto"), icon: "wand.and.stars"),
        PickerOption(value: "on", label: String(localized: "On")),
        PickerOption(value: "off", label: String(localized: "Off")),
    ]
    private let regions = [
        PickerOption(value: "eu", label: String(localized: "Europe")),
        PickerOption(value: "us", label: String(localized: "United States")),
        PickerOption(value: "asia", label: String(localized: "Asia")),
        PickerOption(value: "auto", label: String(localized: "Nearest"), icon: "location"),
        PickerOption(value: "none", label: String(localized: "None")),
    ]

    var body: some View {
        PageScaffold(String(localized: "Component gallery")) {
            switchesSection
            valuesSection
            pickersSection
            buttonsSection
            displaysSection
            listSection
            reorderSection
            gaugesSection
            chartsSection
            tilesSection
            dialogSection
        }
        .task { await feedCharts() }
    }

    private var switchesSection: some View {
        SectionGroup(String(localized: "Switches"), footer: String(localized: "Click or drag. Space toggles a focused switch.")) {
            SwitchRow(String(localized: "On"), icon: "power", isOn: $switches[0])
            SwitchRow(String(localized: "Off"), icon: "moon", isOn: $switches[1])
            SwitchRow(String(localized: "Tinted"), icon: "paintpalette", isOn: $switches[2], tint: .blue)
            SwitchRow(String(localized: "Busy"), icon: "hourglass", isOn: $busySwitch, isBusy: true)
            SwitchRow(String(localized: "Disabled"), icon: "lock", isOn: .constant(true)).disabled(true)
            SwitchRow(String(localized: "Disabled, off"), icon: "lock", isOn: .constant(false)).disabled(true)
            SwitchRow(String(localized: "A long label that needs two lines to fit next to its switch"), isOn: $switches[1])
        }
    }

    private var valuesSection: some View {
        SectionGroup(String(localized: "Sliders and steppers")) {
            SliderRow(String(localized: "Volume"), icon: "speaker.wave.2", value: $volume, in: 0...100, unit: "%")
            SliderRow(String(localized: "Steps"), icon: "slider.horizontal.3", value: $steps, in: 0...10, step: 1, tint: .orange)
            SliderRow(String(localized: "Disabled"), value: .constant(30), in: 0...100, unit: "%").disabled(true)
            StepperRow(String(localized: "Retries"), icon: "arrow.clockwise", value: $count, in: 0...5)
            StepperRow(String(localized: "Interval"), icon: "timer", value: .constant(0.5), in: 0...2, step: 0.25, unit: " s")
            StepperRow(String(localized: "Disabled"), value: .constant(3)).disabled(true)
        }
    }

    private var pickersSection: some View {
        SectionGroup(String(localized: "Pickers and text")) {
            PickerRow(String(localized: "Mode"), icon: "dial.medium", selection: $mode, options: modes)
            PickerRow(selection: $mode, options: modes)
            PickerRow(String(localized: "Region"), icon: "globe", selection: $region, options: regions)
            PickerRow(String(localized: "Disabled"), selection: .constant("on"), options: modes).disabled(true)
            TextFieldRow(String(localized: "Host"), icon: "server.rack", placeholder: "1.1.1.1", value: host) { host = $0 }
            TextFieldRow(placeholder: String(localized: "Search"), value: "") { _ in }
            TextFieldRow(String(localized: "Disabled"), value: "read only") { _ in }.disabled(true)
        }
    }

    private var buttonsSection: some View {
        SectionGroup(String(localized: "Buttons")) {
            HStack(spacing: 8) {
                GlassButton(String(localized: "Normal"), fillsWidth: true) {}
                GlassButton(String(localized: "Prominent"), kind: .prominent, fillsWidth: true) {}
                GlassButton(String(localized: "Remove"), kind: .destructive, fillsWidth: true) {}
            }
            HStack(spacing: 8) {
                GlassButton(String(localized: "Refresh"), icon: "arrow.clockwise", fillsWidth: true) {}
                GlassButton(String(localized: "Applying"), kind: .prominent, isBusy: true, fillsWidth: true) {}
            }
            HStack(spacing: 8) {
                GlassButton(String(localized: "Open website"), icon: "safari", fillsWidth: true) {}
                GlassButton(String(localized: "Disabled"), icon: "nosign", fillsWidth: true) {}.disabled(true)
            }
            HStack {
                Text("Icon buttons").font(.rowLabel)
                Spacer(minLength: 0)
                IconButton("ellipsis", label: String(localized: "More")) {}
                IconButton("trash", label: String(localized: "Delete")) {}.disabled(true)
            }
        }
    }

    private var displaysSection: some View {
        SectionGroup(String(localized: "Text and values"), footer: String(localized: "Footer text explains a section in a sentence or two.")) {
            StyledText(String(localized: "Title text"), style: .title)
            StyledText(String(localized: "Body text wraps over several lines when it is longer than the tile is wide."))
            StyledText(String(localized: "Caption text"), style: .caption)
            StyledText("~/Library/Application Support/Toolsy", style: .mono)
            StyledText(String(localized: "Tinted text"), tint: Tint.color("teal"))
            ValueRow(String(localized: "Address"), value: "192.0.2.10", icon: "network", copyable: true)
            ValueRow(String(localized: "Status"), value: String(localized: "Connected"), icon: "checkmark.shield", tint: Tint.color("ok"))
            ValueRow(String(localized: "Long value"), value: "a-very-long-identifier-that-does-not-fit-0123456789", icon: "textformat")
            HStack(spacing: 14) {
                StatusLabel(String(localized: "Active"), level: .ok)
                StatusLabel(String(localized: "Slow"), level: .warn)
                StatusLabel(String(localized: "Failed"), level: .error)
                StatusLabel(String(localized: "Off"), level: .off)
            }
            HStack(spacing: 4) {
                ForEach(["red", "orange", "yellow", "green", "mint", "teal", "cyan", "blue", "indigo", "purple", "pink", "brown", "gray"], id: \.self) {
                    IconBadge("star.fill", tint: Tint.color($0), size: 18)
                }
            }
            HStack(spacing: 4) {
                ForEach(ModLook.palette, id: \.self) {
                    IconBadge("star.fill", tint: Tint.color($0), size: 18, isLit: false)
                }
            }
            HStack(spacing: 8) {
                IconBadge("bolt.fill", tint: Tint.color("#FF6A00"))
                IconBadge("leaf.fill", tint: Tint.color("ok"))
                IconBadge("exclamationmark", tint: Tint.color("warn"))
                IconBadge("xmark", tint: Tint.color("error"))
                IconBadge("moon.fill", tint: Tint.color("off"))
                IconBadge("questionmark", tint: Tint.color("not-a-colour"))
                IconBadge("no.such.symbol", tint: .purple)
            }
            if showsBanner {
                InlineBanner(String(localized: "The helper could not be reached. Try again or reinstall it from Settings."),
                             kind: .error) { withAnimation(Motion.snappy) { showsBanner = false } }
            }
            InlineBanner(String(localized: "This mod runs commands as administrator."), kind: .warning)
        }
    }

    private var listSection: some View {
        SectionGroup(String(localized: "Lists")) {
            ListRow("en0", subtitle: String(localized: "Wi-Fi"), value: "192.0.2.10", icon: "wifi", tint: .blue)
            ListRow("utun4", subtitle: String(localized: "Tunnel"), value: String(localized: "up"), icon: "lock.shield", tint: .green) {}
            ListRow(String(localized: "Plain row"), value: "42")
            ListRow(String(localized: "Clickable row")) {}
            EmptyState(String(localized: "Nothing here"), symbol: "tray", message: String(localized: "An empty list shows this placeholder."),
                       actionTitle: String(localized: "Refresh")) {}
        }
    }

    private var reorderSection: some View {
        SectionGroup(String(localized: "Reorderable rows"), footer: String(localized: "Drag a row into another place.")) {
            ReorderableRows(arranged, rowHeight: 40) { id, index in
                guard let from = arranged.firstIndex(where: { $0.id == id }) else { return }
                arranged.insert(arranged.remove(at: from), at: index)
            } row: { row in
                HStack(spacing: 10) {
                    IconBadge(row.symbol, tint: row.tint, size: 24)
                    Text(row.name).font(.rowLabel)
                    Spacer(minLength: 8)
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(.rect)
            }
        }
    }

    private var gaugesSection: some View {
        SectionGroup(String(localized: "Gauges")) {
            BarGauge(String(localized: "Download"), icon: "arrow.down.circle", value: volume, text: formatNumber(volume.rounded(), unit: "%"))
            BarGauge(String(localized: "Disk"), icon: "internaldrive", value: 91, text: "91%", tint: .orange)
            BarGauge(value: 12, text: "", tint: .red)
            HStack(spacing: 0) {
                RingGauge(value: volume, text: formatNumber(volume.rounded(), unit: "%"), label: String(localized: "Level"))
                    .frame(maxWidth: .infinity)
                RingGauge(value: 82, text: "82", tint: .orange, label: String(localized: "Load"))
                    .frame(maxWidth: .infinity)
                RingGauge(value: 4, text: "4%", tint: .red, size: 40, label: String(localized: "Low"))
                    .frame(maxWidth: .infinity)
                RingGauge(value: 100, text: "100", tint: .green, size: 64)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var chartsSection: some View {
        SectionGroup(String(localized: "Charts"), footer: String(localized: "Fed one sample a second while this page is open.")) {
            SeriesChart(String(localized: "Latency"), series: [ChartSeries(tint: .blue, values: samples)], unit: " ms")
            SeriesChart(String(localized: "Load"), series: [ChartSeries(tint: .purple, values: samples)], style: .area, min: 0, max: 100, unit: "%")
            SeriesChart(String(localized: "Traffic"), series: [
                ChartSeries(String(localized: "In"), tint: .cyan, values: samples),
                ChartSeries(String(localized: "Out"), tint: .orange, values: secondSamples),
            ], unit: " KB/s")
            SeriesChart(String(localized: "Requests"), series: [ChartSeries(tint: .green, values: bars)], style: .bar, capacity: 24)
            SeriesChart(String(localized: "Two series"), series: [
                ChartSeries(String(localized: "A"), tint: .pink, values: Array(bars.suffix(12))),
                ChartSeries(String(localized: "B"), tint: .indigo, values: Array(secondSamples.suffix(12))),
            ], style: .bar, capacity: 12)
            SeriesChart(String(localized: "No data"), series: [ChartSeries(values: [])])
        }
    }

    private var tilesSection: some View {
        Group {
            Tile {
                StyledText(String(localized: "A static tile holds any content."))
            }
            Tile(action: {}) {
                HStack {
                    IconBadge("hand.tap.fill", tint: .blue)
                    StyledText(String(localized: "An interactive tile reacts to hover and press."))
                }
            }
            Tile(tint: Tint.color("purple")) {
                StyledText(String(localized: "A tinted tile carries a mod's colour."))
            }
        }
    }

    private var dialogSection: some View {
        SectionGroup(String(localized: "Dialogs")) {
            HStack(spacing: 8) {
                GlassButton(String(localized: "Confirm…"), fillsWidth: true) {
                    panel.confirm(ConfirmationRequest(
                        title: String(localized: "Apply the new settings?"),
                        message: String(localized: "The network connection restarts for a moment."),
                        confirmTitle: String(localized: "Apply"),
                        onConfirm: {}
                    ))
                }
                GlassButton(String(localized: "Destructive…"), kind: .destructive, fillsWidth: true) {
                    panel.confirm(ConfirmationRequest(
                        title: String(localized: "Allow “VPN Protector” to run as administrator?"),
                        message: String(localized: "These commands will run as root without asking again:"),
                        details: ["bin/protector apply", "bin/protector repair", "bin/protector remove"],
                        confirmTitle: String(localized: "Allow"),
                        isDestructive: true,
                        onConfirm: {}
                    ))
                }
            }
        }
    }

    // MARK: Demo data

    private static func seed(_ count: Int, base: Double) -> [Double] {
        (0..<count).map { base + 18 * sin(Double($0) / 4) + Double(($0 * 37) % 11) }
    }

    private func feedCharts() async {
        var step = samples.count
        while !Task.isCancelled {
            do { try await Task.sleep(for: .seconds(1)) } catch { return }  // the page went away
            step += 1
            let wave = sin(Double(step) / 4)
            append(40 + 18 * wave + Double((step * 37) % 11), to: &samples, limit: 60)
            append(20 + 10 * cos(Double(step) / 3), to: &secondSamples, limit: 60)
            append(50 + 30 * wave + Double((step * 13) % 17), to: &bars, limit: 24)
        }
    }

    private func append(_ value: Double, to values: inout [Double], limit: Int) {
        values.append(value)
        if values.count > limit { values.removeFirst(values.count - limit) }
    }
}

/// A row of the gallery's reorderable list.
private struct GalleryRow: Identifiable {
    var name: String
    var symbol: String
    var tint: Color

    var id: String { symbol }
}
#endif
