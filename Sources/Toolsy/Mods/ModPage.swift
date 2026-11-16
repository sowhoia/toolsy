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

    var body: some View {
        let manifest = mod.manifest
        PageScaffold(
            manifest.name,
            subtitle: [manifest.version, manifest.author].compactMap(\.self).joined(separator: " · "),
            badge: PageBadge(symbol: manifest.icon ?? "puzzlepiece.extension.fill", tint: Tint.color(manifest.tint))
        ) {
            AttentionBanners(mod: mod)
            if manifest.ui.isEmpty {
                PlainModTile(mod: mod)
            } else {
                ModControls(mod: mod)
            }
            AboutMod(mod: mod)
        } accessory: {
            if mod.hasSwitch {
                ModSwitch(mod: mod)
                    .padding(.trailing, 8)
                    .debugAnchor("page-switch")
            }
        }
    }
}

/// Missing administrator access with the one action that fixes it, and the mod's current error.
private struct AttentionBanners: View {
    let mod: Mod
    @Environment(ModsModel.self) private var model

    var body: some View {
        if let remedy = ModInterface.remedy(for: mod.access) {
            // Changed files are a warning, not just something missing.
            InlineBanner(ModInterface.explanation(of: remedy, modName: mod.manifest.name).message,
                         kind: remedy == .reinstallModified ? .error : .warning,
                         action: InlineBanner.Action(
                             title: remedy == .updateHelper ? String(localized: "Update…") : String(localized: "Choose File…"),
                             isBusy: remedy == .updateHelper && model.isChangingHelper,
                             perform: { model.fixAccess(of: mod) }
                         ))
        }
        if let error = mod.error {
            InlineBanner(ModInterface.displayedError(error, of: mod.manifest), kind: .error) {
                withAnimation(Motion.snappy) { mod.dismissError() }
            }
            .debugAnchor("error-banner")
        }
    }
}

/// The page of a mod whose manifest declares no interface: what it is and how it is doing.
private struct PlainModTile: View {
    let mod: Mod

    var body: some View {
        Tile {
            VStack(spacing: 6) {
                IconBadge(mod.manifest.icon ?? "puzzlepiece.extension.fill", tint: Tint.color(mod.manifest.tint), size: 44)
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

/// Summary, website and removal.
private struct AboutMod: View {
    let mod: Mod
    @Environment(ModsModel.self) private var model

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
        GlassButton(String(localized: "Remove Mod…"), icon: "trash", kind: .destructive,
                    isBusy: model.removing.contains(mod.id), fillsWidth: true) {
            model.remove(mod)
        }
        .debugAnchor("remove-mod")
    }
}
