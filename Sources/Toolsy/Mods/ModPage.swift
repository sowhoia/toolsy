import AppKit
import SwiftUI
import ToolsyEngine
import ToolsyShared

/// The page of one installed mod: header with its switch, what needs attention, its interface as
/// the manifest describes it, and what the mod is.
///
/// The page body depends only on the manifest; each part below reads the state it shows, so a patch
/// re-renders controls in place without re-creating them (focus, drags and spinners survive).
struct ModPage: View {
    let id: String
    @Environment(ModsModel.self) private var model

    var body: some View {
        if let mod = model.mod(id: id) {
            ModPageContent(mod: mod)
        } else if let problem = model.store.loadProblems.first(where: { $0.folder == id }) {
            // Its folder stopped loading, as when a mod being edited has a mistake; fixed, the mod comes back here.
            PageScaffold(id) {
                Tile {
                    EmptyState(String(localized: "This mod couldn’t be loaded"), symbol: "exclamationmark.triangle",
                               message: problem.message)
                        .textSelection(.enabled)
                }
            }
        } else {
            // Removed (or replaced by a version that failed to load) while its page was open.
            PageScaffold(String(localized: "Mod")) {
                Tile {
                    EmptyState(String(localized: "This mod is no longer installed"), symbol: "puzzlepiece.extension")
                }
            }
        }
    }
}

private struct ModPageContent: View {
    let mod: Mod
    @Environment(ModsModel.self) private var model

    var body: some View {
        let manifest = mod.manifest
        let appearance = model.appearance(of: mod)
        // Under a name of the user's own, the manifest's says which mod this is.
        let subtitle = appearance.isRenamed ? [manifest.name, manifest.version] : [manifest.version, manifest.author].compactMap(\.self)
        PageScaffold(
            appearance.name,
            subtitle: subtitle.joined(separator: " · "),
            badge: PageBadge(symbol: appearance.symbol, tint: appearance.tint, isLit: !mod.hasSwitch || model.isSwitchedOn(mod))
        ) {
            AttentionBanners(mod: mod)
            if manifest.ui.isEmpty {
                PlainModTile(mod: mod)
            } else {
                ModControls(mod: mod)
            }
            if !manifest.widgets.isEmpty {
                ModWidgetsSection(mod: mod)
            }
            PresentationSection(mod: mod)
            AboutMod(mod: mod)
            if model.developerMode {
                DeveloperSection(mod: mod)
            }
            RemoveModButton(mod: mod)
        } accessory: {
            if mod.hasSwitch {
                ModSwitch(mod: mod)
                    .padding(.trailing, 8)
                    .debugAnchor("page-switch")
            }
        }
        .environment(\.modTint, appearance.tint)
    }
}

/// Missing administrator access with the one action that fixes it, and the mod's current error.
private struct AttentionBanners: View {
    let mod: Mod
    @Environment(ModsModel.self) private var model

    var body: some View {
        let name = model.appearance(of: mod).name
        if let remedy = ModInterface.remedy(for: mod.access) {
            // Changed files are a warning, not just something missing.
            InlineBanner(ModInterface.explanation(of: remedy, modName: name).message,
                         kind: remedy == .reinstallModified ? .error : .warning,
                         action: InlineBanner.Action(
                             title: remedy == .updateHelper ? String(localized: "Update…") : String(localized: "Choose File…"),
                             isBusy: remedy == .updateHelper && model.isChangingHelper,
                             perform: { model.fixAccess(of: mod) }
                         ))
        }
        if let error = mod.error {
            InlineBanner(ModInterface.displayedError(error, of: mod.manifest, named: name), kind: .error) {
                withAnimation(Motion.snappy) { mod.dismissError() }
            }
            .debugAnchor("error-banner")
        }
    }
}

/// The page of a mod whose manifest declares no interface: what it is and how it is doing.
private struct PlainModTile: View {
    let mod: Mod
    @Environment(ModsModel.self) private var model

    var body: some View {
        let appearance = model.appearance(of: mod)
        Tile {
            VStack(spacing: 6) {
                IconBadge(appearance.symbol, tint: appearance.tint, size: 44, isLit: !mod.hasSwitch || model.isSwitchedOn(mod))
                    .padding(.bottom, 4)
                if let status = mod.status, !status.isEmpty {
                    StatusLabel(status, level: mod.level.flatMap { StatusLevel(rawValue: $0.rawValue) } ?? .off)
                }
                if let summary = mod.manifest.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.system(size: 13))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(mod.hasSwitch
                     ? String(localized: "This mod has no settings. Turn it on or off with the switch above.")
                     : String(localized: "This mod has no settings."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
    }
}

/// The mod's dashboard widgets, each with its current value and a switch that puts it on the dashboard
/// or takes it off.
private struct ModWidgetsSection: View {
    let mod: Mod
    @Environment(DashboardStore.self) private var dashboard
    @Environment(ModsModel.self) private var model

    var body: some View {
        let appearance = model.appearance(of: mod)
        SectionGroup(String(localized: "Widgets")) {
            ForEach(mod.manifest.widgets, id: \.id) { widget in
                let info = WidgetInfo(id: .mod(mod.id, widget: widget.id), content: .mod(mod, widget, appearance))
                HStack(spacing: 10) {
                    IconBadge(info.symbol, tint: info.tint, size: 24)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(info.name).font(.rowLabel).lineLimit(1)
                        Text(mod.render(widget.value))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .contentTransition(.identity)
                    }
                    Spacer(minLength: 8)
                    GlassSwitch(isOn: Binding(get: { dashboard.contains(info.id) },
                                              set: { $0 ? dashboard.add(info.id) : dashboard.remove(info.id) }),
                                label: String(localized: "Show “\(info.name)” on the dashboard"))
                        .debugAnchor("widget-switch:\(info.id.rawValue)")
                }
                .frame(minHeight: Metrics.rowMinHeight)
            }
        }
        .debugAnchor("mod-widgets")
    }
}

/// How the mod looks in Toolsy: the way to its appearance.
private struct PresentationSection: View {
    let mod: Mod
    @Environment(ModsModel.self) private var model
    @Environment(PanelState.self) private var panel

    var body: some View {
        let appearance = model.appearance(of: mod)
        SectionGroup {
            ListRow(String(localized: "Appearance"), subtitle: String(localized: "Name, colour and icon"),
                    value: model.preferences.look(of: mod.id).isEmpty ? nil : String(localized: "Your own"),
                    icon: appearance.symbol, tint: appearance.tint) {
                panel.push(.modAppearance(mod.id))
            }
            .debugAnchor("mod-appearance")
        }
    }
}

/// Summary and website.
private struct AboutMod: View {
    let mod: Mod

    var body: some View {
        let manifest = mod.manifest
        // The plain page already shows the summary.
        let summary = manifest.ui.isEmpty ? nil : manifest.summary.flatMap { $0.isEmpty ? nil : $0 }
        let website = manifest.homepage.flatMap(URL.init(string:))
        if summary != nil || website != nil {
            SectionGroup(String(localized: "About This Mod")) {
                if let summary {
                    StyledText(summary)
                }
                if let website {
                    ListRow(String(localized: "Website"), value: website.host(), icon: "safari", tint: .blue) {
                        NSWorkspace.shared.open(website)
                    }
                }
            }
        }
    }
}

private struct RemoveModButton: View {
    let mod: Mod
    @Environment(ModsModel.self) private var model

    var body: some View {
        GlassButton(String(localized: "Remove Mod…"), icon: "trash", kind: .destructive,
                    isBusy: model.removing.contains(mod.id), fillsWidth: true) {
            model.remove(mod)
        }
        .debugAnchor("remove-mod")
    }
}
