# Toolsy

A menu bar app for macOS 26. Its panel shows a brief summary of the Mac — CPU, memory, battery,
network, storage — and a list of **mods**: small features you install from a file and switch on
and off. Mods can show switches, sliders, pickers, text fields, buttons, gauges, charts and
lists, and can do their work with administrator privileges without asking for the password
every time.

Toolsy is native (Swift, AppKit, SwiftUI, Liquid Glass), has no third-party dependencies and
idles at zero CPU: nothing runs while the panel is closed except what a mod you switched on
declares.

## Install

Requires macOS 26 and Xcode 26 (or its command line tools).

```sh
scripts/install.sh       # builds, installs /Applications/Toolsy.app, restarts it
scripts/build-mods.sh    # builds the mods in Mods/ into dist/*.toolsymod
```

Toolsy starts at login (switch it off in its settings). To install a mod, drop its
`.toolsymod` file on the menu bar icon or the panel, press **+**, or double-click the file.
To remove one, open its page and choose **Remove mod…**.

## Mods

A mod is a folder with a `mod.json` manifest and, optionally, the programs it runs. Toolsy
renders the manifest natively and starts the programs on demand, in their own processes — a
mod is never loaded into the app, can be written in any language, and costs nothing while it
is off. The format is specified in [docs/MOD_FORMAT.md](docs/MOD_FORMAT.md).

```sh
/Applications/Toolsy.app/Contents/Helpers/toolsy-mod validate path/to/mod
/Applications/Toolsy.app/Contents/Helpers/toolsy-mod pack path/to/mod -o name.toolsymod
```

Mods in this repository:

| Mod | What it does |
| --- | --- |
| [`Mods/vpn-protector`](Mods/vpn-protector) | System kill switch: PF rules that let traffic out only through the VPN tunnel. Needs administrator access. |
| [`Mods/showcase`](Mods/showcase) | A harmless demo that uses every control of the format. |

## Administrator access

Some mods must act as root. The first time you install one, Toolsy installs a small helper;
that is the only time macOS asks for an administrator password. Installing such a mod is what
allows it: the confirmation lists the commands that will run as root, and from then on the mod
works without prompts.

The helper starts on demand and exits when idle. It accepts requests only from the build of
Toolsy it was installed by, and it runs only the copy of a mod it stored when you installed it.
If the files of an installed mod are changed later, its root commands stop until you install
it again from its file. After Toolsy itself is updated or rebuilt the helper has to be
authorised once more. Remove the helper from Toolsy's settings; that needs no password. The
design and its threat model are described in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Where things are

| Path | Contents |
| --- | --- |
| `~/Library/Application Support/Toolsy/Mods/` | Installed mods, one folder each |
| `~/Library/Application Support/Toolsy/State/` | Each mod's settings and switch position |
| `~/Library/Application Support/Toolsy/Data/` | Each mod's own files |
| `/Library/PrivilegedHelperTools/app.toolsy.helper` | The helper (only after administrator access was set up) |
| `/Library/LaunchDaemons/app.toolsy.helper.plist` | Its launchd job |
| `/Library/Application Support/Toolsy/` | The copies of mods allowed to run as root |

To uninstall: remove the helper in Toolsy's settings, quit Toolsy, then delete
`/Applications/Toolsy.app` and `~/Library/Application Support/Toolsy`.

## Development

```
Package.swift            the app (target Toolsy)
Sources/Toolsy/          shell, design system, dashboard, mods UI
Packages/ToolsyShared/   the contract: mod format, command protocol, process runner
Packages/ToolsyEngine/   mod runtime and the toolsy-mod tool
Packages/ToolsyPrivileged/  the root helper, its XPC interface and client
Mods/                    mods maintained here
scripts/                 build-app.sh, build-mods.sh, install.sh, make-icon.swift
docs/                    MOD_FORMAT.md, ARCHITECTURE.md
```

```sh
swift test                                          # app
(cd Packages/ToolsyShared && swift test)
(cd Packages/ToolsyEngine && swift test)
(cd Packages/ToolsyPrivileged && swift test)
scripts/build-app.sh --debug                        # build/Toolsy.app
```

`scripts/build-app.sh` signs ad hoc by default; set `TOOLSY_SIGN_IDENTITY` to use a signing
identity. `swift scripts/make-icon.swift` regenerates the app icon.
