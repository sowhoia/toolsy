# Changelog

All notable changes to Toolsy are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
  use the most CPU or memory, counted the way Activity Monitor does, and can ask an app to quit
  after a confirmation.
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
- The app bundle is 4.8 MB.

### Fixes

- The panel stays in place and inside its glass when its height changes, such as when opening
  Settings or a tile's details.
- An idle network or disk reads "0 KB/s" instead of "Zero KB/s".
