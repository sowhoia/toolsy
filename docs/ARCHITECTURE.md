# Toolsy architecture

Toolsy is a macOS menu bar app. Its panel shows a dashboard of widgets the user arranges (readings
of the Mac and tiles of mods) and a list of *mods*: small features users install from a file and
switch on and off. The format of a mod is specified in [MOD_FORMAT.md](MOD_FORMAT.md), and for AI
models that write mods in [MOD_AUTHORING_FOR_AI.md](MOD_AUTHORING_FOR_AI.md).

## Why it is built this way

- **Swift, AppKit shell, SwiftUI content, no third-party dependencies.** Liquid Glass exists
  only as a native material (`glassEffect`, `NSGlassEffectView`), and a menu bar app that must
  idle at zero CPU should not carry a web runtime. Requires macOS 26.
- **Mods are data plus processes, not plug-in code.** A mod is a JSON manifest that Toolsy
  renders natively, and programs Toolsy starts on demand. Nothing of a mod is loaded into the
  app, so a mod cannot crash or slow it, mods can be written in any language, and a mod that
  is off costs nothing. The host needs no embedded interpreter.
- **Root work goes through one small helper.** macOS asks for the administrator password once,
  when the helper is installed. After that privileged mods run without prompts.

## Layout

```
Package.swift            the app (executable target Toolsy)
Sources/Toolsy/          App/ (shell, panel, system events, notifications), DesignSystem/,
                         Dashboard/, System/ (readings, processes, memory optimiser), Mods/
                         (pages, controls, developer mode), Settings/, Debug/ (scripted runs)
Packages/
  ToolsyShared/          the contract: mod format, command protocol, process runner,
                         PrivilegedExecuting. Foundation only.
  ToolsyEngine/          mod runtime: install/remove, state, commands, services, refresh,
                         the observable model the UI renders; the toolsy-mod tool. No UI.
  ToolsyPrivileged/      the root helper daemon, its XPC interface, and the client + installer
                         the app uses.
Mods/                    mods maintained in this repository (keep-awake, timer, network-info,
                         showcase, vpn-protector), each with a test.sh and a build.sh
scripts/                 building the .app, packing mods
docs/                    MOD_FORMAT.md, MOD_AUTHORING_FOR_AI.md, ARCHITECTURE.md
```

Dependencies point one way: `Toolsy → ToolsyEngine, ToolsyHelperClient → ToolsyShared`, and
`ToolsyHelper → ToolsyShared`. The engine knows privileged execution only as the
`PrivilegedExecuting` protocol; the app hands it the XPC client.

## Running a mod

State of a mod is one flat JSON object: persisted *settings* plus *live* values reported by
commands. The UI is a pure function of manifest and state.

```
control changes / switch flips / timer fires
        │
        ▼
 engine: per-mod serial queue ──► unprivileged: ProcessRunner (child process, own process group,
        │                          timeout, bounded output)
        │                     └─► privileged:   PrivilegedExecuting ─XPC─► helper ─► ProcessRunner as root
        ▼
 stdout JSON patch ──► merged into state ──► SwiftUI re-renders, chart histories advance
```

A mod's `service` is the one long-lived process: the engine keeps it alive while the mod is on
and applies each line it prints as a patch. It runs beside the queue, not in it. `refresh` commands
are scheduled only while the panel is open unless the mod asks for background refresh. With the
panel closed and no service running, Toolsy has no timers.

Each `Mod` keeps the history of every chart-bound key (as many samples as the largest chart showing
it) and its last 20 runs (`recentRuns`: command, cause, duration, outcome, the end of standard error;
never state or standard output, which can hold user data), each in a property of its own so that
recording one re-renders nothing else. Templates and expressions are parsed once per source text and
cached; a patch that changes nothing writes nothing.

`ModStore` is created with the user's preferred languages. It loads every manifest through its first
matching `localizations` table (`ModManifest.localized(for:)`), so pages, tiles and the installation
confirmation are shown translated, and tells commands the first language as `TOOLSY_LOCALE`. State
keys, commands and settings are never translated.

System events reach mods through `SystemEventMonitor` in the app, which observes only the events
some installed mod declares (`ModStore.observedEvents`) and follows that set as mods come and go:
wake from `NSWorkspace.didWakeNotification`, power from `IOPSCreateLimitedPowerNotification` (posted
only when the providing source actually changes), network from the dynamic store keys of the
primary interface and of the interfaces' addresses, link-local IPv6 excluded and a burst settled
into one event after two quiet seconds. Power and network are posted only for real changes: each
source reports its condition (the providing power source; the primary interface, its router and
every interface's addresses) and an event is posted when it differs from the last one; a wake is an
event every time. Nothing is replayed after sleep.

A mod's `notify` goes through the store's rate limit (one per mod every 5 seconds, no repeat within
a minute) to `ModNotifier`, which asks for permission the first time one arrives, drops them while
permission is refused, posts each as a banner without sound grouped by mod (`threadIdentifier`), and
opens the panel on the mod's page when one is clicked. A debug run on scratch data prints
notifications instead of posting them.

On disk, per user (`~/Library/Application Support/Toolsy/`):

```
Mods/<id>/        the unpacked mod, exactly as installed
State/<id>.json   {"enabled": …, "settings": {…}}
Data/<id>/        the mod's writable folder (TOOLSY_DATA_DIR)
Run/<id>.json     pid and start time of the mod's running service
Dashboard.json    the dashboard's layout (see below)
DeveloperMode     an empty marker file, present while developer mode is on
```

Services are children of the app, each in its own process group. Quitting stops them. Should the
app die without doing so, the next launch reads `Run/` and stops whatever is still running before
it starts anything, so a crash never leaves a second copy of a service behind.

Installing a mod whose id is installed replaces it in place: the old instance is closed (its service
stopped, no hook run), the new files are moved in, and the new instance starts from the saved
settings and switch position, its first command waiting for the old one's last. `ModsModel` puts the
mod's widgets on the dashboard only when no folder with that id existed before, so an update leaves
the user's arrangement alone; removing a mod takes them off.

### Developer mode

A switch in Settings, saved as the marker file `DeveloperMode` in the data root, so a debug run on
scratch data never sees the user's choice. While it is on, `ModStore` watches the mods folder with
FSEvents and acts once changes have settled for 0.3 s: a changed `mod.json` (compared by digest)
reloads the mod, keeping its settings and switch position; changes to its other files restart its
running service, at most once a second, so a mod writing into its own folder cannot restart itself
as fast as it writes; a folder that appears is loaded and one that disappears is dropped, keeping
its saved settings. A folder that does not load is listed with its error on its page and comes back
once fixed. Each mod's page then ends with a Reload button, its folder and its recent runs. Nothing is
approved this way: a privileged mod edited in place loses its administrator access as always.

## The dashboard

`DashboardStore` owns the layout: whether the device line is shown, and the widgets in reading order,
each a `PlacedWidget` (its `WidgetID` and the options the user chose: size, chart style, network rate
unit; an option left unset follows the widget's own default, for a mod widget its manifest, so an
update can change it). A built-in widget's id is its metric (`cpu`, `memory`, `battery`, `network`,
`storage`, `gpu`, `disk`), a mod's is `mod:<mod id>/<widget id>`. The layout is saved to
`Dashboard.json` (`{"version": 1, "showsDeviceLine", "widgets"}`) after every change. Loading never
fails: a missing, unreadable, damaged or newer file gives the standard layout and is left alone until
the user changes something; ids that cannot be shown (a mod that is not installed) are kept in place,
so the layout survives a mod being reinstalled.

Packing the grid is a pure function of the widgets and their sizes: rows of three columns fill in
order, and the last tile of a row that is not full stretches, so the grid has no holes. In edit mode
tiles are dragged, selected for their options and removed, and added back from a list.

A mod's widget is drawn from its manifest and the mod's state on every change, like a page: the
caption, the rendered `value`, a sparkline from `Mod.history(of:)` or a level bar, in the mod's tint,
dimmed while a mod with a switch is off. Expanding it lays out its `detail` controls with the same
views as the mod's page, followed by a row that opens the page; without `detail` the tile opens the
page.

## Readings of the Mac

`SystemMonitor` samples about once a second, only while the panel is visible, and only the metrics
of the widgets on the dashboard (`shownMetrics`, set by the dashboard): a metric that is not placed
costs nothing. Rates (CPU, network, disk) take a fresh baseline whenever sampling starts; slow
readings are taken less often (battery every 5 seconds, storage every 30, the primary interface's
name and address every 10 and only while something shows them). GPU utilisation and disk activity
come from the I/O Registry; the dashboard offers only the metrics this Mac reports.

`ProcessMonitor` lists the user's apps by memory and CPU for the memory and CPU details. It is
demand-driven like the system monitor: views that show a list start and stop it (counted, so several
can want it), and it samples only while one wants it and the panel is visible, every 2.5 seconds, off
the main thread, with libproc. It groups processes the way a person thinks of apps: everything inside
one outermost `.app` bundle, XPC services with the app macOS holds responsible for them, and every
other process on its own. Memory is the physical footprint (Activity Monitor's Memory column), CPU is
per core. It can ask a regular app (not Toolsy or Finder) to quit the normal way, after a
confirmation in the panel.

`MemoryOptimizer` drives the memory detail's **Free Up Memory** button. With the helper ready it asks
it to reclaim memory (below); with the helper missing or outdated it first asks in the panel and
installs it through `ModStore`, so the mods' access is refreshed too, and a dismissed password prompt
is an answer, not an error. The result is measured: free memory before and a second after, never
negative, the change of memory used, and the helper's report of which steps it carried out.

## Privileged execution

```
/Library/PrivilegedHelperTools/app.toolsy.helper      the helper (root-owned)
/Library/LaunchDaemons/app.toolsy.helper.plist        starts it on demand for the Mach service
/Library/Application Support/Toolsy/                  root-owned store
    client-requirement                                code requirement the app must satisfy
    client-user                                       the user the helper works for
    Mods/<id>/                                        approved snapshots        (Mods and Data are
    Data/<id>/                                        TOOLSY_DATA_DIR of        readable by root only)
                                                      privileged commands
```

The helper is a launchd daemon started on demand and exiting when idle. It offers six
operations over XPC: list approved mods, approve (store a snapshot), revoke, run a privileged
command of an approved mod, reclaim memory, and uninstall itself.

Reclaiming memory is the one operation not tied to an approved mod. It runs `/usr/sbin/purge`
(flushes the disk cache), then `/usr/bin/memory_pressure -S -l warn -s 3`, which holds the system
at the *warn* memory-pressure level for three seconds: every process gets the standard warning, on
which the allocator returns free pages and apps drop caches they can rebuild. Nothing is terminated;
the *critical* level, on which apps may discard work in use, is never used. `memory_pressure` sets the
level back itself only when its sleep ends, so whenever it does not exit successfully the helper runs
`memory_pressure -S -l normal -s 0`. Only the helper itself dying within those seconds would leave the
level at *warn*, until the next reclaim or restart.

Threat model: code running as the logged-in user must not be able to become root through
Toolsy without the user's consent.

- **Only the app can talk to the helper.** At install time the app's code directory hash is
  written to `client-requirement`; the helper rejects every XPC peer that does not satisfy
  `cdhash H"…"`. An ad-hoc signature is enough for this, and unlike a certificate-based
  requirement it cannot be satisfied by other code signed with the developer's own key. The
  cost: after the app is rebuilt or updated the helper must be re-authorised once.
- **Only for the user who installed it.** The installer also records that user's id, and the
  helper refuses peers running as anyone else: one user's administrator password must not give
  root to every account that can start the app. Another administrator of the same Mac takes
  the helper over by installing it again; the approvals of the previous user's mods end there.
- **The helper never executes user-writable files.** A mod is approved while it is being
  installed: the app reads the package into memory, checks it, builds the confirmation from
  those bytes and sends exactly those bytes over XPC. The helper writes them into its store and
  runs commands only from there, with the command definitions of the stored manifest.
- **Nothing is approved from a mod's folder.** That folder is writable by the user, and so by
  every mod and every other program running as the user. The app compares the digest of the
  installed files with the approved one; when they differ, the mod's privileged commands are
  refused, and the only way back is to install the mod again from a package. That is a
  deliberate act with its own confirmation, not a routine click on a familiar mod.
- **Approvals do not outlive their mods.** Removing a mod, or updating it to a version that runs
  nothing as root, revokes its approval. If the helper cannot be asked at that moment (it awaits
  an update), neither goes through, except a forced removal, which leaves the approval behind.
  Whenever the helper is reachable, the app revokes approvals that belong to no installed mod
  with privileged commands. That cleanup takes the approval only: whether a mod's folder exists
  is in the hands of every program of the user, and must not be enough to make root delete the
  mod's data.
- **Reclaiming memory takes nothing from the client.** The request has no parameters: the two
  programs, their absolute paths, argument lists, environment (`PATH` only), working directory and
  timeouts are constants in the helper, and their output only reaches the helper's log when a
  step fails. A client can only decide
  when it runs, and only one runs at a time (a second request is answered "busy"). The worst a
  hostile or buggy client that passed the checks above can do is run it repeatedly: a cold disk
  cache and apps rebuilding caches slow the Mac down, but no data is changed and no process is
  stopped.
- **What the app passes at run time is data.** The command input goes to the program's stdin
  and to `TOOLSY_*` variables, never into a command line. Privileged programs validate it.
- **A privileged command that has started runs to its end** (or its own timeout) even if the app
  quits or crashes meanwhile: a root program is never killed halfway through changing the system
  because its client went away. Requests that would pull its files from under it (removing the
  helper, replacing or revoking the mod's approval) are answered "busy" until it has finished. The
  same holds for a memory reclaim: the helper does not exit and cannot be removed in the middle of
  one.
- **The app is hardened.** It is signed with the hardened runtime and without
  `get-task-allow`, so other user processes cannot inject code into it to borrow its identity.
- Consent is the confirmation shown when a mod is installed, which lists the commands that will
  run as root; it is not a password prompt. This is the convenience the product is for; the
  residual risk is someone with control of the user's session clicking through that
  confirmation.
- The administrator prompt remains the trust boundary for the helper itself: whoever can replace
  the app on disk, or the helper inside its bundle (which the app then offers as an update), can
  make it ask for the password, as with any software that installs a privileged component.
  Toolsy does not try to defend a user who authorises a tampered app.

The helper is installed by a fixed script run once through the system administrator prompt.
Removing it (from Settings) needs no password: the helper deletes its own files.

## Performance rules

- No polling while the panel is closed, except what an enabled mod explicitly declares.
- System metrics are sampled only while the panel is visible, and only those a widget on the
  dashboard shows; processes only while a list of them is on screen.
- Charts are drawn with paths; no charting framework is loaded.
- Nothing that changes by itself animates in SwiftUI. A reading that ticks every second replaces
  its text at once (`tickingValue()`), and the motion that is worth seeing, a chart sliding by one
  sample or a gauge moving to its new value, is a Core Animation animation of a layer, which the
  render server runs. SwiftUI drives its animations from the app's process, a transaction per frame,
  so a handful of values animating every second keeps the panel busy all the time: the open, idle
  dashboard used 10.6 % of a core that way and uses 0.6 % now, a mod's page with three gauges and
  two charts fed every second 9.2 % and now 1.0 % (M4, release build, `top` over 10 s).
- Everything a mod does happens outside the app process.
