# Toolsy

A menu bar app for macOS 26. Its panel opens on a dashboard of the Mac — CPU, memory, battery,
network, storage, GPU and disk activity — that you arrange yourself, and below it a list of
**mods**: small features you install from a file and switch on and off, such as keeping the Mac
awake or a focus timer. Mods can show switches, sliders, pickers, text fields, buttons, gauges,
charts and lists, put their own tiles on the dashboard, offer buttons, toggles and pickers right on
their card and in the menu bar icon's menu, send notifications, and do their work with
administrator privileges without asking for the password every time.

Toolsy is native (Swift, AppKit, SwiftUI, Liquid Glass), has no third-party dependencies and
idles at zero CPU: nothing runs while the panel is closed except what a mod or an alert you
switched on needs, and a check for updates about once a day (which you can switch off).

## Install

**From a release.** Download the release archive from the repository's Releases page, unzip it and
move `Toolsy.app` to `/Applications`. It runs on Apple silicon and Intel Macs, and `SHA256SUMS`
beside it lists the checksum of every file of the release. If macOS refuses to open it the first
time because it cannot check it for malicious software, open **System Settings → Privacy &
Security** and click **Open Anyway**. From then on Toolsy updates itself (see [Updates](#updates)).

**From source.** Requires macOS 26 and Xcode 26 (or its command line tools).

```sh
scripts/install.sh       # builds, installs /Applications/Toolsy.app, restarts it
scripts/build-mods.sh    # builds the mods in Mods/ into dist/*.toolsymod
```

Toolsy starts at login (switch it off in its settings). To install a mod, drop its
`.toolsymod` file on the menu bar icon or the panel, press **+**, or double-click the file.
To remove one, open its page and choose **Remove mod…**.

## The dashboard

The panel opens on a line about the Mac (model, chip, system, uptime, thermal state) and a grid of
three columns. Click a tile to unfold its details under its row: CPU lists the apps and the system's
own processes (such as WindowServer) using the most of it, memory the apps holding the most, the
battery its cycles and how much it holds next to when it was new, and the memory detail can also
free up memory (below).

Choose **Customise** (the grid button, or a tile's context menu) to arrange the dashboard: drag
tiles to a new place, select one for its options (size, chart style, bytes or bits for the network
rate) or remove it, add widgets back from the list underneath, hide the line about the Mac, or reset
everything to the standard layout. The mods are arranged there too (see [Your mods](#your-mods)). The built-in widgets are CPU, Memory, Battery (on a Mac
with one), Network, Storage, GPU and Disk Activity. Only the widgets on the dashboard are measured,
and only while the panel is open.

Mods can add widgets of their own. A mod's widgets are placed on the dashboard when the mod is
installed for the first time; afterwards you switch each one on or off on the mod's page or in the
editor. A mod's tile unfolds the quick controls the mod gives it, or opens the mod's page; its context
menu opens the mod or turns it on or off.

## Freeing up memory

The memory detail has a **Free Up Memory** button. It flushes the disk cache and then puts the Mac
under brief, mild memory pressure for three seconds, which is how macOS itself asks every app to
return memory it can do without. It closes nothing and never uses the level at which apps may drop
work in use. Afterwards it says how much memory the apps gave back, measured a second later as the
fall of Memory used, and how far the file cache shrank. That cache is memory macOS hands out the
moment anything needs it, so clearing it gains nothing by itself, and the Mac reads those files from
disk again. It needs Toolsy's administrator helper: the first time, Toolsy asks whether to install
it, and macOS asks for your password once.

## Alerts

Settings has four alerts, each off until you switch it on: memory pressure getting high, the Mac
getting hot, the battery at 20 % or less while on battery power, and less than 10 GB free on the
startup disk. Each notifies once when its condition starts and again only after it has cleared. They
follow the system's own events; only the disk, which reports nothing, is looked at when its alert is
switched on, on wake and about every half hour. An alert that is off costs nothing.

## Updates

Toolsy checks for a new version shortly after it starts and then about once a day, says so once
with a notification, and offers it at the top of the panel and in Settings. **Update and Restart**
downloads it, checks it, puts it in the place of the running app and opens the new version, which
says what it was updated from; **What's New** opens the release's page. Put the offer away with its
cross and the panel offers the next version again; Settings keeps offering this one. Nothing is
downloaded before you click, and nothing changes until every check has passed:

- the release's archive must carry a signature by Toolsy's release key, whose public half is in the
  app (`ToolsyUpdatePublicKey` in its Info.plist), over the version, the size and the SHA-256 of
  exactly that archive;
- the app in it must be Toolsy in that version, for this Mac and its version of macOS, with an
  intact code signature, by the same Developer ID team once Toolsy is signed with one;
- Toolsy waits until no dialog is open and no mod or helper is being installed, and the new app
  takes the old one's place in a single rename, so one or the other is there at every moment.

A copy that cannot replace itself (one macOS runs from where it was downloaded, or one in a folder
you may not change) offers the download instead and says why. The check asks GitHub's API for the
latest release of this repository and sends nothing about you: an `Accept` header,
`Toolsy/<version>` as its user agent and a fixed language, without cookies or a cache; downloading
the update sends the same. Switch off **Check for Updates Automatically** in Settings to stop
checking, or use **Check Now**. After an update, macOS asks once more for the administrator password
the next time the helper is needed (see [Administrator access](#administrator-access)).

Settings also has **Copy Diagnostics**: text for a bug report with the versions, this Mac, the mods
and what they ran lately, never their settings or what they printed.

## Mods

A mod is a folder with a `mod.json` manifest and, optionally, the programs it runs. Toolsy
renders the manifest natively and starts the programs on demand, in their own processes — a
mod is never loaded into the app, can be written in any language, and costs nothing while it
is off.

Mods in this repository:

| Mod | What it does |
| --- | --- |
| [`Mods/keep-awake`](Mods/keep-awake) | Keeps the Mac awake for a while or until switched off, optionally with the display on. |
| [`Mods/timer`](Mods/timer) | A focus timer: work and break phases with a notification when each ends. |
| [`Mods/network-info`](Mods/network-info) | Addresses, router, DNS and Wi-Fi details of the current connection, read locally. |
| [`Mods/showcase`](Mods/showcase) | A harmless demo of every part of the mod format. |
| [`Mods/vpn-protector`](Mods/vpn-protector) | System kill switch: PF rules that let traffic out only through the VPN tunnel. Needs administrator access. |

Each mod's README says what it runs and what it never does. `scripts/build-mods.sh` packs them all.

Installing asks first, and the confirmation says what matters: every mod runs its own programs with
your permissions, so it can open and change your files and use the network; which commands run as
root, for a mod that has them; and who signed the package. An author can sign packages with a key
of their own, and Toolsy remembers which key signed each installed mod: an update signed by another
key, or not signed at all, comes with a warning that it may not be from the same author, as does an
update that names another author.

### Your mods

The list under the dashboard shows at a glance which mods are on: a mod that is on glows in its
colour, with its badge lit and its switch in its colour; one that is off keeps its icon, unlit. A mod
can put a few **quick controls** under its name: buttons, toggles and pickers for what you do with it
most, such as resetting the timer, copying the address or choosing how long to keep the Mac awake.
Each mod's context menu turns it on or off, offers its quick controls, opens it, hides it or leads
to:

- **Appearance**, also on the mod's page: give the mod a name, a colour and an icon of your own. They
  apply wherever Toolsy shows the mod — the list, its page, its widgets and its controls — and each
  falls back to the mod's own, which **Use the Mod's Own Look** brings back. The page's subtitle then
  names the mod as its author did.
- **Arrange Mods**, also the arrows beside **+**, which opens **Customise** at the mods: drag them into
  the order you like, hide the ones you rarely open, and choose how the list looks, as **Cards** or
  **Compact** rows. A hidden mod keeps working and keeps its widgets; it waits in **Hidden** at the end
  of the list.

A right click on the menu bar icon lists the mods in the list that have a switch or quick controls,
ticked while on: one click switches a mod that has only its switch, and a mod with quick controls has
a submenu with its switch, its quick controls and a way to its page. Nothing of this needs the panel
open.

## Writing mods

`toolsy-mod` writes, checks, runs and packs mods without the app. It ships inside Toolsy:

```sh
alias toolsy-mod=/Applications/Toolsy.app/Contents/Helpers/toolsy-mod
toolsy-mod new my-mod --template widget     # a working mod to start from: basic, switch, service, widget
toolsy-mod validate my-mod                  # the checks installing runs, and likely mistakes
toolsy-mod run my-mod read                  # one command, run exactly as Toolsy runs it
toolsy-mod preview my-mod                   # what the quick controls, page and widgets show for a state
toolsy-mod pack my-mod -o my-mod.toolsymod
toolsy-mod keygen author.key                # once: a key to sign your mods; keep it private
toolsy-mod pack my-mod --sign author.key    # a signed package
```

**Developer mode**, a switch in Toolsy's settings, helps while you work on an installed mod: Toolsy
reloads a mod when its `mod.json` changes and restarts its service when its other files change, and
each mod's page ends with a Reload button, its folder and its recent runs with their errors.

Two documents describe mods:

- [docs/MOD_FORMAT.md](docs/MOD_FORMAT.md) — the format, for people.
- [docs/MOD_AUTHORING_FOR_AI.md](docs/MOD_AUTHORING_FOR_AI.md) — a self-contained specification for
  AI models that write mods. Give it to the model together with a sentence describing the mod you
  want; it tells the model how to choose the mod's shape (and which actions deserve quick controls),
  write it from a template, check every command with `toolsy-mod`, and hand you the files, the packed
  mod and what it runs. If the model cannot run commands, it gives you the exact `toolsy-mod` commands
  to run and asks for their output.

## Administrator access

Some mods must act as root. The first time you install one, Toolsy installs a small helper;
that is the only time macOS asks for an administrator password. Installing such a mod is what
allows it: the confirmation lists the commands that will run as root, and from then on the mod
works without prompts. Freeing up memory uses the same helper.

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
| `~/Library/Application Support/Toolsy/Run/` | The running service of each mod, so a crash leaves none behind |
| `~/Library/Application Support/Toolsy/Signers/` | The key that signed each installed mod, for mods that came signed |
| `~/Library/Application Support/Toolsy/Dashboard.json` | The dashboard's widgets, order and options |
| `~/Library/Application Support/Toolsy/ModPreferences.json` | The order of the mods, the hidden ones, the list's style, and the names, colours and icons you gave them |
| `~/Library/Application Support/Toolsy/Settings.json` | The alerts switched on, whether to check for updates and the version that ran last |
| `~/Library/Application Support/Toolsy/DeveloperMode` | Present while developer mode is on |
| `/Library/PrivilegedHelperTools/app.toolsy.helper` | The helper (only after administrator access was set up) |
| `/Library/LaunchDaemons/app.toolsy.helper.plist` | Its launchd job |
| `/Library/Application Support/Toolsy/` | The copies of mods allowed to run as root |

To uninstall: remove the helper in Toolsy's settings, quit Toolsy, then delete
`/Applications/Toolsy.app` and `~/Library/Application Support/Toolsy`.

## Development

```
Package.swift            the app (target Toolsy)
Sources/Toolsy/          shell, design system, dashboard, system readings, mods UI
Packages/ToolsyShared/   the contract: mod format, command protocol, process runner
Packages/ToolsyEngine/   mod runtime and the toolsy-mod tool
Packages/ToolsyPrivileged/  the root helper, its XPC interface and client
Mods/                    mods maintained here
scripts/                 build-app.sh, build-mods.sh, install.sh, release.sh, sign-update.swift,
                         make-icon.swift
docs/                    MOD_FORMAT.md, MOD_AUTHORING_FOR_AI.md, ARCHITECTURE.md
.github/workflows/       ci.yml: what every push and pull request is checked with
AGENTS.md                the rules for coding agents working on this repository
```

```sh
swift test                                          # app
(cd Packages/ToolsyShared && swift test)
(cd Packages/ToolsyEngine && swift test)            # also checks the docs and every mod in Mods/
(cd Packages/ToolsyPrivileged && swift test)
scripts/build-app.sh --debug                        # build/Toolsy.app
```

`scripts/build-app.sh` builds universal binaries (arm64 and x86_64) and keeps their debug symbols in
`build/*.dSYM`; `--debug` builds for this Mac only. It signs ad hoc by default; set
`TOOLSY_SIGN_IDENTITY` to a Developer ID Application identity to sign with it and a secure timestamp.
`scripts/release.sh` makes a release from a commit tagged `vX.Y.Z` whose version Info.plist,
`ToolsyVersion.swift` and the newest heading of the changelog agree on: it builds and checks the
app, notarizes and staples it with the notarytool profile `TOOLSY_NOTARY_PROFILE`, packs the mods and
writes the archive, `SHA256SUMS` and the release notes to `dist/release/`, keeping the debug symbols
there unpublished; `--publish` creates the GitHub release (`--ad-hoc`, `--skip-notarization` and
`--allow-beta` exist for trying it out). It also signs the archive for the updater with the release
key, `~/.config/toolsy/update-signing.key` unless `TOOLSY_UPDATE_KEY` names another file: a key made
once with `toolsy-mod keygen`, kept out of the repository, whose public half is
`ToolsyUpdatePublicKey` in `Resources/Info.plist` (`swift scripts/sign-update.swift --public-key
<key>` prints it). Keep a backup of it: installed copies refuse an update signed with any other key
and only link to its page. To move to a new key, publish one release signed with the old key whose
Info.plist names the new one. CI runs the four test suites, the tests of `vpn-protector`,
ShellCheck, `scripts/build-mods.sh`, each mod's `test.sh` and a universal build on macOS 26. The mods'
`build.sh` pack the same bytes from the same sources. `swift scripts/make-icon.swift` regenerates the
app icon. Each mod in `Mods/` has a
`test.sh` that runs its commands as Toolsy does. The engine's tests require every mod there (but
`vpn-protector`, written in Russian) to translate all of its text into Russian, with an entry even
for text that reads the same (`"macOS": "macOS"`). The mod format, the `toolsy-mod` command line and
the files on disk are contracts: existing mods and saved state must keep working.

The documentation is in English; the app is in English and Russian
(`Resources/ru.lproj/Localizable.strings`).

## License and security

Toolsy is released under the [MIT License](LICENSE). To report a vulnerability, see
[SECURITY.md](SECURITY.md).
