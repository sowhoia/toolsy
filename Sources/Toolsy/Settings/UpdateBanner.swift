import SwiftUI
import ToolsyShared

/// The update on the dashboard, above the widgets: a new version on offer, its installation under way, or that Toolsy
/// was just updated. The offer can be put away there until a newer version comes; Settings keeps offering it.
struct UpdateBanner: View {
    @Environment(UpdateChecker.self) private var updates
    @Environment(UpdateInstaller.self) private var installer

    var body: some View {
        if let installation = installer.installation {
            UpdateCard(Self.title(of: installation), symbol: "arrow.down.circle.fill", tint: .accentColor) {
                switch installation.phase {
                case .installing, .restarting:
                    ProgressView().controlSize(.small)
                case .failed:
                    PutAwayButton(help: String(localized: "Dismiss")) { installer.dismissFailure() }
                case .downloading:
                    EmptyView()
                }
            } content: {
                InstallationStatus(installation: installation)
            }
            .debugAnchor("update-banner")
        } else if let previous = updates.updatedFrom {
            UpdateCard(String(localized: "Toolsy was updated to \(updates.running.description)"),
                       subtitle: String(localized: "from version \(previous.description)"),
                       symbol: "checkmark.circle.fill", tint: .green) {
                GlassButton(String(localized: "What’s New")) { updates.openRunningVersionPage() }
                    .debugAnchor("update-whats-new")
            }
            .debugAnchor("update-banner")
        } else if case .available(let release) = updates.status, updates.isOfferedOnDashboard(release) {
            UpdateCard(String(localized: "Toolsy \(release.version.description) is available"),
                       subtitle: UpdateOffer.summary(of: release, running: updates.running),
                       symbol: "arrow.down.circle.fill", tint: .accentColor) {
                PutAwayButton(help: String(localized: "Hide until the next version. Settings still offers this one.")) {
                    updates.putAwayOffer(of: release)
                }
            } content: {
                UpdateOffer(release: release)
            }
            .debugAnchor("update-banner")
        }
    }

    /// What the installation is doing, as the title of its card or row.
    static func title(of installation: UpdateInstaller.Installation) -> String {
        let version = installation.release.version.description
        return switch installation.phase {
        case .downloading: String(localized: "Downloading Toolsy \(version)…")
        case .installing: String(localized: "Installing Toolsy \(version)…")
        case .restarting: String(localized: "Restarting Toolsy…")
        case .failed: String(localized: "Toolsy \(version) wasn’t installed")
        }
    }
}

/// A new version on offer: what's new in it, the button that installs it (or downloads it, where this copy cannot
/// install it), and what to know first.
struct UpdateOffer: View {
    let release: LatestRelease
    @Environment(UpdateChecker.self) private var updates
    @Environment(UpdateInstaller.self) private var installer

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                GlassButton(String(localized: "What’s New")) { updates.openPage(of: release) }
                    .debugAnchor("update-whats-new")
                if installer.canInstall(release) {
                    GlassButton(String(localized: "Update and Restart"), icon: "arrow.down.circle", kind: .prominent, fillsWidth: true) {
                        installer.install(release)
                    }
                    .debugAnchor("update-install")
                } else {
                    GlassButton(String(localized: "Download Update"), icon: "arrow.up.right.square", kind: .prominent, fillsWidth: true) {
                        updates.openPage(of: release)
                    }
                    .debugAnchor("update-download")
                }
            }
            UpdateNotes(release: release)
        }
    }

    /// "You have 1.1.0 · 3 MB": the version installed, and how much the update downloads.
    static func summary(of release: LatestRelease, running: ReleaseVersion) -> String {
        let installed = String(localized: "You have \(running.description)")
        guard let package = release.package else { return installed }
        return "\(installed) · \(Format.storage(package.size))"
    }
}

/// What to know before updating: why this copy of Toolsy cannot install the update by itself, or that the
/// administrator helper will need the password once more.
private struct UpdateNotes: View {
    let release: LatestRelease
    @Environment(UpdateInstaller.self) private var installer
    @Environment(ModsModel.self) private var mods

    var body: some View {
        if let obstacle = installer.obstacle {
            note(obstacle.message)
        } else if release.package == nil {
            note(String(localized: "This release can’t be installed from here. Download it and replace Toolsy in Applications."))
        } else if mods.store.helperStatus != .notInstalled {
            // The helper accepts only the build that installed it (docs/ARCHITECTURE.md, "Privileged execution").
            note(String(localized: "Afterwards, macOS asks for your password once to update Toolsy’s helper."))
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// An update under way or one that failed: the download's bar and its Cancel button, what installing does, or why it
/// failed with the ways on from there.
struct InstallationStatus: View {
    let installation: UpdateInstaller.Installation
    @Environment(UpdateChecker.self) private var updates
    @Environment(UpdateInstaller.self) private var installer

    var body: some View {
        switch installation.phase {
        case let .downloading(received, total):
            let fraction = total > 0 ? min(Double(received) / Double(total), 1) : 0
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(Format.storage(received)) of \(Format.storage(total))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .tickingValue()
                    LevelBar(fraction: fraction)
                        .accessibilityElement()
                        .accessibilityLabel(String(localized: "Download progress"))
                        .accessibilityValue(Format.percent(fraction))
                }
                GlassButton(String(localized: "Cancel")) { installer.cancel() }
                    .debugAnchor("update-cancel")
            }
        case .installing:
            caption(String(localized: "Toolsy checks the update, puts it in place and restarts by itself."))
        case .restarting:
            caption(String(localized: "The new version opens in a moment."))
        case .failed(let error):
            VStack(alignment: .leading, spacing: 10) {
                InlineBanner(error.message, kind: .error)
                HStack(spacing: 8) {
                    GlassButton(String(localized: "Download Update"), icon: "arrow.up.right.square", fillsWidth: true) {
                        updates.openPage(of: installation.release)
                    }
                    .debugAnchor("update-download")
                    if error.isWorthRetrying {
                        GlassButton(String(localized: "Try Again"), kind: .prominent, fillsWidth: true) { installer.install(retried) }
                            .debugAnchor("update-retry")
                    }
                }
            }
        }
    }

    /// The release to try again: a newer one found since, or the one that failed.
    private var retried: LatestRelease {
        if case .available(let latest) = updates.status, latest.version > installation.release.version { return latest }
        return installation.release
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A tile with an icon, a title and what goes with it.
private struct UpdateCard<Accessory: View, Content: View>: View {
    private let title: String
    private let subtitle: String?
    private let symbol: String
    private let tint: Color
    private let accessory: Accessory
    private let content: Content

    init(_ title: String, subtitle: String? = nil, symbol: String, tint: Color,
         @ViewBuilder accessory: () -> Accessory = { EmptyView() }, @ViewBuilder content: () -> Content = { EmptyView() }) {
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.tint = tint
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        Tile(padding: 12) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    IconBadge(symbol, tint: tint, size: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.system(size: 13, weight: .semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        if let subtitle {
                            Text(subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    Spacer(minLength: 4)
                    accessory
                }
                content
            }
        }
    }
}

/// The small cross that puts something away.
private struct PutAwayButton: View {
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
                .frame(width: 22, height: 22)
        }
        .buttonStyle(RowButtonStyle())
        .foregroundStyle(.secondary)
        .help(help)
        .accessibilityLabel(String(localized: "Dismiss"))
        .debugAnchor("update-put-away")
    }
}
