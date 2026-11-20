import AppKit
import SwiftUI
import ToolsyEngine

/// The mods on the root page: a header with the install button, the mods in the user's order as cards or as the
/// rows of one group, the hidden ones folded away at the end, the folders that failed to load, or the empty state.
struct ModsSection: View {
    @Environment(ModsModel.self) private var model
    @Environment(PanelState.self) private var panel
    @Environment(DashboardStore.self) private var dashboard
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let store = model.store
        let preferences = model.preferences
        let arranged = model.arrangedMods
        let shown = arranged.filter { !preferences.isHidden($0.id) }
        let hidden = arranged.filter { preferences.isHidden($0.id) }
        VStack(spacing: Metrics.tileSpacing) {
            HStack {
                Text("Mods")
                    .font(.system(size: 13, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if model.isInstalling {
                    ProgressView().controlSize(.small).padding(.trailing, 4)
                }
                if !arranged.isEmpty {
                    IconButton("arrow.up.arrow.down", label: String(localized: "Arrange Mods…")) {
                        ModsArrangement.show(dashboard: dashboard, panel: panel, reduceMotion: reduceMotion)
                    }
                    .debugAnchor("arrange-mods")
                }
                IconButton("plus", label: String(localized: "Install a mod…"), action: chooseMods)
                    .debugAnchor("install")
            }
            .padding(.leading, Metrics.tilePadding)
            .padding(.trailing, (Metrics.headerHeight - Metrics.iconButtonSize) / 2)
            .padding(.top, 2)

            if !shown.isEmpty {
                switch preferences.listStyle {
                case .cards:
                    ForEach(shown) { mod in
                        ModCard(mod: mod)
                    }
                case .compact:
                    SectionGroup {
                        ForEach(shown) { mod in
                            CompactModRow(mod: mod)
                        }
                    }
                }
            }
            if !hidden.isEmpty {
                @Bindable var model = model
                SectionGroup(String(localized: "Hidden (\(hidden.count))"), isExpanded: $model.showsHiddenMods) {
                    ForEach(hidden) { mod in
                        CompactModRow(mod: mod)
                    }
                }
                .debugAnchor("hidden-mods")
            }
            ForEach(store.loadProblems) { problem in
                LoadProblemTile(problem: problem)
            }
            if store.mods.isEmpty, store.loadProblems.isEmpty {
                Tile {
                    EmptyState(
                        String(localized: "No mods yet"),
                        symbol: "puzzlepiece.extension",
                        message: String(localized: "Add a .toolsymod file with + or drop it on the menu bar icon.")
                    )
                }
            }
        }
    }

    private func chooseMods() {
        model.chooseAndInstall()
    }
}

/// One installed mod as a card: icon, name, one status line and the main switch. Clicking it opens the mod's page.
private struct ModCard: View {
    let mod: Mod
    @Environment(ModsModel.self) private var model
    @Environment(PanelState.self) private var panel

    var body: some View {
        let appearance = model.appearance(of: mod)
        let isOn = mod.hasSwitch && model.isSwitchedOn(mod)
        // A mod that is on glows in its colour; one without a switch is always ready, so its badge is lit.
        Tile(tint: isOn ? appearance.tint : nil, padding: 10, action: { panel.push(.mod(mod.id)) }) {
            HStack(spacing: 10) {
                IconBadge(appearance.symbol, tint: appearance.tint, size: 32, isLit: isOn || !mod.hasSwitch)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(appearance.name)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        ModAttention(mod: mod)
                    }
                    statusLine
                }
                Spacer(minLength: mod.hasSwitch ? GlassSwitch.trackSize.width + 12 : 0)
            }
        }
        // On top of the tile's button rather than inside it, so a click on the switch is the switch's.
        .overlay(alignment: .trailing) {
            if mod.hasSwitch {
                ModSwitch(mod: mod)
                    .padding(.trailing, 12)
                    .debugAnchor("tile-switch:\(mod.id)")
            }
        }
        .contextMenu { ModMenu(mod: mod) }
        .debugAnchor("tile:\(mod.id)")
    }

    @ViewBuilder
    private var statusLine: some View {
        if let status = mod.status, !status.isEmpty {
            ModStatus(mod: mod, status: status)
        } else if let summary = mod.manifest.summary, !summary.isEmpty {
            Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

/// One installed mod as a row of a group: icon, name, its status beside it and the main switch. Clicking it opens the
/// mod's page.
private struct CompactModRow: View {
    let mod: Mod
    @Environment(ModsModel.self) private var model
    @Environment(PanelState.self) private var panel

    var body: some View {
        let appearance = model.appearance(of: mod)
        let isOn = mod.hasSwitch && model.isSwitchedOn(mod)
        Button { panel.push(.mod(mod.id)) } label: {
            HStack(spacing: 10) {
                IconBadge(appearance.symbol, tint: appearance.tint, size: 26, isLit: isOn || !mod.hasSwitch)
                HStack(spacing: 5) {
                    Text(appearance.name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    ModAttention(mod: mod)
                }
                .layoutPriority(1)
                Spacer(minLength: 8)
                if let status = mod.status, !status.isEmpty {
                    ModStatus(mod: mod, status: status)
                }
                if mod.hasSwitch {
                    // The switch lies over this room, outside the row's button.
                    Color.clear.frame(width: GlassSwitch.trackSize.width)
                }
            }
            .frame(minHeight: Metrics.rowMinHeight)
            .contentShape(.rect)
        }
        .buttonStyle(RowButtonStyle())
        .overlay(alignment: .trailing) {
            if mod.hasSwitch {
                ModSwitch(mod: mod)
                    .debugAnchor("tile-switch:\(mod.id)")
            }
        }
        .contextMenu { ModMenu(mod: mod) }
        .debugAnchor("tile:\(mod.id)")
    }
}

/// A mod's status with the dot of its level, or as plain text without one.
private struct ModStatus: View {
    let mod: Mod
    let status: String

    var body: some View {
        if let level = mod.level.flatMap({ StatusLevel(rawValue: $0.rawValue) }) {
            StatusLabel(status, level: level)
        } else {
            Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

/// A quiet mark next to a mod's name when something needs the user: a failure or missing access.
private struct ModAttention: View {
    let mod: Mod
    @Environment(ModsModel.self) private var model

    var body: some View {
        let remedy = ModInterface.remedy(for: mod.access)
        let name = model.appearance(of: mod).name
        if remedy == .reinstallModified {
            SymbolImage("exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.red)
                .help(ModInterface.explanation(of: .reinstallModified, modName: name).title)
                .accessibilityLabel(String(localized: "Files changed after installation"))
        } else if let error = mod.error {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.red)
                .help(ModInterface.displayedError(error, of: mod.manifest, named: name))
                .accessibilityLabel(String(localized: "Error"))
        } else if remedy != nil {
            Image(systemName: "lock.fill")
                .font(.system(size: 10))
                .foregroundStyle(.orange)
                .help(String(localized: "Needs administrator access"))
                .accessibilityLabel(String(localized: "Needs administrator access"))
        }
    }
}

/// The context menu of a mod in the list: open it, switch it, change how it looks or where it is listed, remove it.
struct ModMenu: View {
    let mod: Mod
    @Environment(ModsModel.self) private var model
    @Environment(PanelState.self) private var panel
    @Environment(DashboardStore.self) private var dashboard
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let isHidden = model.preferences.isHidden(mod.id)
        Button(String(localized: "Open"), systemImage: "arrow.right.circle") { panel.push(.mod(mod.id)) }
        if mod.hasSwitch {
            let isOn = model.isSwitchedOn(mod)
            Button(isOn ? String(localized: "Turn Off") : String(localized: "Turn On"), systemImage: "power") {
                model.setEnabled(mod, !isOn)
            }
            .disabled(!model.canSwitch(mod))
        }
        Divider()
        Button(String(localized: "Appearance…"), systemImage: "paintbrush") { panel.push(.modAppearance(mod.id)) }
        Button(isHidden ? String(localized: "Show in the List") : String(localized: "Hide from the List"),
               systemImage: isHidden ? "eye" : "eye.slash") {
            withAnimation(Motion.resolve(Motion.gentle, reduceMotion: reduceMotion)) { model.preferences.setHidden(!isHidden, mod.id) }
        }
        Button(String(localized: "Arrange Mods…"), systemImage: "arrow.up.arrow.down") {
            ModsArrangement.show(dashboard: dashboard, panel: panel, reduceMotion: reduceMotion)
        }
        Divider()
        Button(String(localized: "Remove…"), systemImage: "trash", role: .destructive) { model.remove(mod) }
    }
}

/// The main switch of a mod, on its tile and in its page header, in the mod's colour.
struct ModSwitch: View {
    let mod: Mod
    @Environment(ModsModel.self) private var model

    var body: some View {
        let appearance = model.appearance(of: mod)
        GlassSwitch(
            isOn: Binding(get: { model.isSwitchedOn(mod) }, set: { model.setEnabled(mod, $0) }),
            isBusy: model.requestedSwitch[mod.id] != nil || mod.isSwitching,
            tint: appearance.tint,
            label: appearance.name
        )
        .disabled(model.removing.contains(mod.id))
    }
}

/// A mod folder that could not be loaded, with its reason and a way to delete it.
private struct LoadProblemTile: View {
    let problem: LoadProblem
    @Environment(ModsModel.self) private var model

    var body: some View {
        Tile(padding: 10) {
            HStack(alignment: .top, spacing: 10) {
                IconBadge("exclamationmark.triangle.fill", tint: .orange, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(problem.folder)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text("Couldn’t be loaded: \(problem.message)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 4)
                GlassButton(String(localized: "Remove…"), kind: .destructive) { model.removeBrokenMod(problem) }
                    .debugAnchor("remove-broken:\(problem.folder)")
            }
        }
    }
}
