# Changelog

All notable changes to Toolsy are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Dashboard

- Alerts in Settings, each off until switched on: memory pressure getting high, the Mac getting hot,
  the battery at 20 % or less on battery power, less than 10 GB free on the startup disk. Each
  notifies once when its condition starts and again only after it has cleared. They follow the
  system's events; only the disk is looked at, every 30 minutes while its alert is on.
- The CPU detail lists other users' processes too (WindowServer, `mds_stores`, …), read with `ps`
  while the list is shown.
- The battery detail shows the cycle count and the full charge as a share of the design capacity.
- Free Up Memory reports what the apps gave back (the fall of Memory used) and, apart, how far the
  file cache shrank, instead of the rise of free memory, which was mostly the flushed cache.
- Read-ahead file pages are no longer counted as both cached files and free memory.
- The "Last minute" charts start afresh when the panel opens instead of running on from an earlier
  opening.
- The network detail finds the interface of an IPv6-only network and names adapters plugged in
  after launch; GPU memory is shown in binary units like all other memory.
- VoiceOver announces the result of Free Up Memory, a copy and a dialog, and reads the network chart
  in the unit chosen for it.

### Panel

- A mod's file can be dropped on the open panel: a click elsewhere closes the panel on release, and
  only away from it.
- The panel closes when the displays or the Mac go to sleep or another user takes the Mac, so
  nothing is measured while nobody can see it.
- The page behind a dialog no longer takes Return or ⌘[; Esc while an input method composes text
  goes to the field; after the open panel, the app that was active gets activation back.

### Updates and settings

- Toolsy checks GitHub for a new version shortly after it starts and about once a day, says so once
  with a notification, and offers it at the top of the panel and in Settings. Update and Restart
  downloads it, checks that Toolsy's release key signed exactly that archive and that it holds Toolsy
  in that version for this Mac, puts it in the place of the running app in one step and opens the new
  version, which says it was updated. Nothing is downloaded before the click, and a copy that cannot
  replace itself offers the download instead. The requests identify nothing but the version of
  Toolsy. Switch the check off in Settings, or check now.
- Copy Diagnostics in Settings: text for a bug report, without mods' settings or output.

### Mods

- The install confirmation says of every mod that its programs run with your permissions, shows who
  signed the package, and warns when an update is signed by another key, is not signed while the
  installed version is, or names another author.
- Signed packages: `toolsy-mod keygen` makes a key and `toolsy-mod pack --sign` signs with it. Toolsy
  verifies the signature and refuses a package changed after it was signed.
- `toolsy` in `mod.json` names the oldest Toolsy a mod works with; `toolsy-mod --version`.
- What a command leaves running is stopped when it exits, so neither its timeout nor the helper's
  lock is outlived by a process it started.
- Every command gets `LANG=en_US.UTF-8`, in Toolsy and in `toolsy-mod run` alike. A state value over
  32 KB, or past 256 KB of them, reaches commands only on standard input: one long value made every
  command of its mod fail with "Argument list too long".
- A package whose `when` or JSON is nested thousands of levels deep no longer crashes Toolsy before
  its confirmation.
- At most 64 lines of a service wait to be applied, where a runaway service could hold gigabytes.
- Reloading, removing and updating one mod at the same time no longer runs two copies of it, revives
  a mod being removed or deletes the update; the helper's status after an update is no longer
  overwritten by an earlier check.

### toolsy-mod

- `pack -o` must name a `.toolsymod` file and replaces no folder: `-o dist` deleted a folder of that
  name with everything in it. A packed folder leaves out `.git`, `.hg`, `.svn` and `.toolsymod` files,
  and the same files always make the same archive.
- An archive's folder entries no longer count against the file limit, and `--option=` with an empty
  value no longer takes the next argument.

### Build and release

- The app, its helper, `toolsy-mod` and `vpn-protector` are universal binaries, for Intel Macs on
  macOS 26 too; the bundle is 10.0 MB.
- `scripts/release.sh` builds, checks, notarizes and packs a release with `SHA256SUMS`, signs the
  app's archive for Toolsy's updater, and keeps the debug symbols for crash reports.
- `scripts/build-app.sh` stops when a build fails, where it packed the previous binaries, and signs
  with a secure timestamp when given an identity.
- CI on macOS 26; the helper's tests no longer fail now and then; ShellCheck finds nothing.
- The example mods call `/usr/bin/jq` and pack reproducibly; the format document's examples check
  their input before using it.
- An MIT license and a security policy.

## [1.0.0] - 2026-11-16

The first public release: a menu bar app for macOS 26 with a dashboard of the Mac and mods.

### Dashboard

- A Liquid Glass panel under the menu bar icon opens on a line about the Mac (model, chip, system,
  uptime, thermal state) and a grid of widgets.
- Built-in widgets for CPU, Memory, Battery, Network, Storage, GPU and Disk Activity; a Mac shows
  only those it can measure.
- Edit Widgets: drag tiles into place, choose a tile's size, chart style and whether the network
  rate is shown in bytes or bits, remove tiles, add them back, hide the line about the Mac, or reset
  to the standard layout. The layout is kept across restarts.
- Click a tile to unfold its details under its row. The CPU and Memory details list the apps that
  use the most CPU or memory, counted the way Activity Monitor does; the Memory list can ask an app
  to quit, after a confirmation.
- Mods can add their own widgets: a value with a small chart or level bar, and quick controls when
  unfolded. A mod's widgets appear on the dashboard when it is installed for the first time, and
  are switched on and off on its page.

### Memory

- Free Up Memory in the Memory detail: flushes the disk cache and asks every app, through a
  three-second mild memory warning, to return memory it does not need. No app is closed.
- The result says how much more memory is free, measured a second later, and whether everything
  could be done.
- The first time, Toolsy offers to install its administrator helper; macOS asks for the password
  once.
- The Memory detail also shows cached files and free memory.

### Mods

- Install a mod by dropping its `.toolsymod` file on the menu bar icon or the panel, with the **+**
  button, or by double-clicking it; remove it from its page.
- Mods show switches, sliders, steppers, pickers, text fields, buttons, values, facts in rows, text,
  gauges, charts, lists and foldable sections, all drawn natively, and run their work in their own
  processes, so a mod cannot slow Toolsy down and costs nothing while it is off.
- Mods can answer the Mac waking, the network or the power source changing and Toolsy starting, and
  can show notifications, which open the mod's page when clicked.
- Mods appear in your language when they include a translation; Keep Awake, Focus Timer, Network
  Info and Showcase are in English and Russian.
- Mods that need administrator access run their commands through a helper installed once; the
  installation confirmation lists every command that will run as root, and a mod whose files are
  changed afterwards loses that access until it is installed again.
- Included mods: Keep Awake (keeps the Mac awake for a while or until switched off), Focus Timer
  (work and break phases with notifications), Network Info (addresses, router, DNS and Wi-Fi,
  read locally), Showcase (every part of the format), and VPN Protector (a firewall kill switch for
  a VPN, needs administrator access).

### For mod authors

- `toolsy-mod` ships inside Toolsy (`Toolsy.app/Contents/Helpers/toolsy-mod`): `new` writes a
  working mod from a template (basic, switch, service, widget), `validate` runs the checks of
  installing and points out likely mistakes, `run` runs one command exactly as Toolsy does and
  explains what Toolsy makes of its output, `preview` prints what the page and widgets show for a
  state, `pack` writes the `.toolsymod` file.
- The mod format ([docs/MOD_FORMAT.md](docs/MOD_FORMAT.md)): widgets, system events,
  notifications, localization, template paths and filters (sizes, rates, durations, times, dates,
  relative times, arithmetic, text and lists), arithmetic and `contains` in expressions, pickers
  fed from state, value formats for gauges and charts, foldable sections, copy buttons, tooltips.
- Developer mode in Settings: an installed mod reloads when its manifest changes and restarts its
  service when its other files change, and its page shows a Reload button, its folder and its
  recent runs with their errors.
- [docs/MOD_AUTHORING_FOR_AI.md](docs/MOD_AUTHORING_FOR_AI.md): a self-contained specification to
  give an AI model that writes a mod for you.

### Performance

- Toolsy idles at zero CPU with the panel closed: readings are taken only while the panel is open,
  only for the widgets on the dashboard, and processes only while a list of them is shown.
- The open, idle dashboard uses about 0.6 % of one core, and a mod's page with three gauges and two
  charts updated every second about 1 % (M4, release build, measured with `top` over 10 s): moving
  charts and gauges are animated by the system's render server, not by the app.
- The app bundle is 5.4 MB.

### Fixes

- The panel stays in place and inside its glass when its height changes, such as when opening
  Settings or a tile's details.
- An idle network or disk reads "0 KB/s" instead of "Zero KB/s".
