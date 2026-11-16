# Toolsy architecture

Toolsy is a macOS menu bar app. Its panel shows a summary of the Mac and a list of *mods*:
small features users install from a file and switch on and off. The format of a mod is
specified in [MOD_FORMAT.md](MOD_FORMAT.md).

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
Sources/Toolsy/          app shell, design system, panel, system monitor
Packages/
  ToolsyShared/          the contract: mod format, command protocol, process runner,
                         PrivilegedExecuting. Foundation only.
  ToolsyEngine/          mod runtime: install/remove, state, commands, services, refresh,
                         the observable model the UI renders; the toolsy-mod tool. No UI.
  ToolsyPrivileged/      the root helper daemon, its XPC interface, and the client + installer
                         the app uses.
Mods/                    mods maintained in this repository (vpn-protector, showcase)
scripts/                 building the .app, packing mods
docs/
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
and applies each line it prints as a patch. `refresh` commands are scheduled only while the
panel is open unless the mod asks for background refresh. With the panel closed and no service
running, Toolsy has no timers.

On disk, per user (`~/Library/Application Support/Toolsy/`):

```
Mods/<id>/        the unpacked mod, exactly as installed
State/<id>.json   {"enabled": …, "settings": {…}}
Data/<id>/        the mod's writable folder (TOOLSY_DATA_DIR)
Run/<id>.json     pid and start time of the mod's running service
```

Services are children of the app, each in its own process group. Quitting stops them. Should the
app die without doing so, the next launch reads `Run/` and stops whatever is still running before
it starts anything, so a crash never leaves a second copy of a service behind.

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
- System metrics are sampled only while the panel is visible.
- Charts are drawn with paths; no charting framework is loaded.
- Nothing that changes by itself animates in SwiftUI. A reading that ticks every second replaces
  its text at once (`tickingValue()`), and the motion that is worth seeing, a chart sliding by one
  sample or a gauge moving to its new value, is a Core Animation animation of a layer, which the
  render server runs. SwiftUI drives its animations from the app's process, a transaction per frame,
  so a handful of values animating every second keeps the panel busy all the time: the open, idle
  dashboard used 10.6 % of a core that way and uses 0.6 % now, a mod's page with three gauges and
  two charts fed every second 9.2 % and now 1.0 % (M4, release build, `top` over 10 s).
- Everything a mod does happens outside the app process.
