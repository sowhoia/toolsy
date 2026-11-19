import AppKit
import SwiftUI
import ToolsyEngine

/// The mods on the root page: a header with the install button, one tile per mod, the folders that
/// failed to load, or the empty state.
struct ModsSection: View {
    @Environment(ModsModel.self) private var model

    var body: some View {
        let store = model.store
        VStack(spacing: Metrics.tileSpacing) {
            HStack {
                Text("Mods")
                    .font(.system(size: 13, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if model.isInstalling {
                    ProgressView().controlSize(.small).padding(.trailing, 4)
                }
                IconButton("plus", label: String(localized: "Install a mod…"), action: chooseMods)
                    .debugAnchor("install")
            }
            .padding(.leading, Metrics.tilePadding)
            .padding(.trailing, (Metrics.headerHeight - Metrics.iconButtonSize) / 2)
            .padding(.top, 2)

            ForEach(store.mods) { mod in
                ModTile(mod: mod)
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

/// One installed mod: icon, name, one status line and the main switch. Clicking it opens the mod's page.
private struct ModTile: View {
    let mod: Mod
    @Environment(ModsModel.self) private var model
    @Environment(PanelState.self) private var panel

    var body: some View {
        let appearance = model.appearance(of: mod)
        Tile(padding: 10, action: open) {
            HStack(spacing: 10) {
                IconBadge(appearance.symbol, tint: appearance.tint, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(appearance.name)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        attention
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
        .contextMenu {
            Button(String(localized: "Open"), action: open)
            Button(String(localized: "Appearance…")) { panel.push(.modAppearance(mod.id)) }
            Divider()
            Button(String(localized: "Remove…"), role: .destructive) { model.remove(mod) }
        }
        .debugAnchor("tile:\(mod.id)")
    }

    private func open() {
        panel.push(.mod(mod.id))
    }

    /// A quiet mark next to the name when something needs the user: a failure or missing access.
    @ViewBuilder
    private var attention: some View {
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

    @ViewBuilder
    private var statusLine: some View {
        if let status = mod.status, !status.isEmpty {
            if let level = mod.level.flatMap({ StatusLevel(rawValue: $0.rawValue) }) {
                StatusLabel(status, level: level)
            } else {
                caption(status)
            }
        } else if let summary = mod.manifest.summary, !summary.isEmpty {
            caption(summary)
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(1)
    }
}

/// The main switch of a mod, on its tile and in its page header.
struct ModSwitch: View {
    let mod: Mod
    @Environment(ModsModel.self) private var model

    var body: some View {
        let requested = model.requestedSwitch[mod.id]
        GlassSwitch(
            isOn: Binding(get: { requested ?? mod.isEnabled }, set: { model.setEnabled(mod, $0) }),
            isBusy: requested != nil || mod.isSwitching,
            label: model.appearance(of: mod).name
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
