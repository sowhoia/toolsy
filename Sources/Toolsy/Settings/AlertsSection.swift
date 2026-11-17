import SwiftUI

/// The switches of the alerts about the Mac, in Settings.
struct AlertsSection: View {
    @Environment(SystemAlerts.self) private var alerts

    var body: some View {
        SectionGroup(
            String(localized: "Alerts"),
            footer: String(localized: "A notification when it happens, and again only once it has passed. Nothing is watched for an alert that is off.")
        ) {
            ForEach(alerts.available, id: \.self) { alert in
                SwitchRow(Self.label(for: alert), icon: Self.icon(for: alert), isOn: Binding(
                    get: { alerts.isOn(alert) },
                    set: { alerts.set(alert, on: $0) }
                ))
                .debugAnchor("alert:\(alert.rawValue)")
            }
            if alerts.notificationsRefused, alerts.available.contains(where: alerts.isOn) {
                Text("Toolsy may not show notifications. Allow them in System Settings → Notifications.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // Permission can change in System Settings while Toolsy runs.
        .task { await alerts.refreshPermission() }
    }

    /// Each label says the threshold the alert uses.
    static func label(for alert: MacAlert) -> String {
        switch alert {
        case .memoryPressure: String(localized: "Memory pressure is high")
        case .heat: String(localized: "The Mac is hot")
        case .lowBattery: String(localized: "Battery at \(Format.percent(Double(MacAlert.lowBatteryPercent) / 100)) or less")
        case .lowDiskSpace: String(localized: "Less than \(Format.storage(MacAlert.lowFreeSpace)) free on the startup disk")
        }
    }

    private static func icon(for alert: MacAlert) -> String {
        switch alert {
        case .memoryPressure: "memorychip"
        case .heat: "thermometer.high"
        case .lowBattery: "battery.25percent"
        case .lowDiskSpace: "internaldrive"
        }
    }
}
