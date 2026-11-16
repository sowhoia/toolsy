# Toolsy mod authoring specification for AI models

You are writing a mod for Toolsy, a menu bar app for macOS 26. This document is all you need: it
explains what a mod is, the procedure from a request to a delivered mod, the complete format, how
to write the mod's scripts, five complete mods to copy from, the mistakes to avoid, and the
checklist to tick before you answer.

How to read it. **MUST** and **MUST NOT** mark rules that Toolsy's validator or runtime enforces, or
whose breach would harm the user; every one of them was checked against Toolsy's code. **SHOULD**
marks the idiom: depart from it only for a reason you can state. Messages in `this style` that
follow "the tool says" are the exact output of `toolsy-mod`. Field names, values and commands are
exact: use them as written, and never use a field, filter, option or event this document does not
name.

## Contents

- [Read this first](#read-this-first)
- [What a mod is](#what-a-mod-is)
- [Procedure](#procedure)
  - [Understand the request](#understand-the-request)
  - [Choose the shape](#choose-the-shape)
  - [Scaffold](#scaffold)
  - [Write](#write)
  - [Verify](#verify)
  - [Pack](#pack)
  - [Deliver](#deliver)
  - [Without a shell](#without-a-shell)
- [Reference](#reference)
  - [Files and packages](#files-and-packages)
  - [Manifest](#manifest)
  - [State](#state)
  - [Commands](#commands)
  - [Lifecycle](#lifecycle)
  - [Interface](#interface)
  - [Widgets](#widgets)
  - [Localization](#localization)
  - [Templates](#templates)
  - [Expressions](#expressions)
  - [Administrator privileges](#administrator-privileges)
  - [What Toolsy does around a mod](#what-toolsy-does-around-a-mod)
  - [Limits](#limits)
  - [toolsy-mod](#toolsy-mod)
- [Script craft](#script-craft)
- [Worked examples](#worked-examples)
- [Mistakes and their fixes](#mistakes-and-their-fixes)
- [Final checklist](#final-checklist)

## Read this first

These rules prevent the mistakes that break a mod. Each is explained in the reference.

1. A mod is a folder: `mod.json` (the manifest) and the programs it names. Toolsy draws the mod's
   page and dashboard tiles natively from the manifest and runs the programs as separate processes
   when something has to happen. A mod cannot run code inside Toolsy, draw its own interface or keep
   a process alive other than its one `service`.
2. Work with the tool, never from memory: `toolsy-mod new` to start, then after every change
   `toolsy-mod validate` (it MUST print `OK <id> <version>` and SHOULD print no `warning:` line),
   `toolsy-mod run` for every command, `toolsy-mod preview` for the page, `toolsy-mod pack` to finish.
   The tool is `/Applications/Toolsy.app/Contents/Helpers/toolsy-mod`.
3. A program reports by printing **one JSON object** on standard output (a *patch*, merged into the
   mod's state) and exiting with status 0. Any other exit status is a failure: the patch is thrown
   away and the last line of standard error is shown to the user. Output that is not a JSON object is
   ignored without an error, so a broken patch fails silently: always check it with `toolsy-mod run`.
4. Build JSON with `/usr/bin/jq -n -c --arg key "$value" '{key: $key}'` (it escapes everything),
   never by pasting a variable into a string such as `"{\"name\": \"$name\"}"`: one quote in the
   text and Toolsy ignores the whole patch.
5. Programs receive their inputs only through `TOOLSY_*` environment variables and, if the command
   sets `"stdin": true`, one JSON document on standard input. Quote every expansion
   (`"$TOOLSY_VALUE"`) and validate it before use. MUST NOT pass input to `eval`, `sh -c` or any
   other place where it is parsed as code.
6. Templates (`{{key|filter}}`) work only in the fields this document marks *template*. `when` and
   `disabled` are *expressions*: `"when": "enabled && count > 0"`, never `"when": "{{enabled}}"`.
7. The keys `enabled`, `status`, `level`, `error` and `notify` belong to Toolsy. They MUST NOT be
   settings, and inputs MUST NOT bind them. Programs set `status`, `level` and `error`, and correct
   `enabled`, through their patches; `notify` in a patch shows a notification.
8. Unknown fields are ignored without an error. A misspelt optional field (`"lable"`, `"title"` on
   a `value` row, `"label"` on a `list`) is not reported; it just does nothing. Use only the field
   names of the reference tables and look at the result with `toolsy-mod preview`.
9. A `service` runs for as long as the mod is on: it MUST NOT exit when it has nothing to do (exit
   status 0 switches the mod off, any other status restarts it after a delay). Each line it prints
   is one patch: print compact JSON (`jq -c`), one object per line, and make sure the line is
   flushed when it is printed.
10. `refresh` runs while the panel is open (and after every other command of the mod). Keep it fast
    and cheap; `"background": true` keeps it running all day and needs a reason.
11. Use only programs that ship with macOS: the mod MUST work on a Mac with nothing else
    installed. Call anything beyond the basic POSIX tools by absolute path (`/usr/bin/jq`), since
    Toolsy's `PATH` searches Homebrew's folders first. Write files only inside `$TOOLSY_DATA_DIR`.
    Never wait for a person: standard input is not a terminal, no program may prompt, and nothing
    may ask for a password (`sudo`).
12. Ask for administrator privileges (`"privileged": true`) only when the job cannot be done
    without root. A privileged command MUST validate every input against an allow-list and MUST NOT
    put text the user typed into a command line it runs as root. A service cannot be privileged.
13. Write the manifest's text in English and translate it under `localizations`; scripts translate
    what they report themselves with `TOOLSY_LOCALE`, the language the mod is shown in. (A manifest
    written in another language says so with `language`.)

## What a mod is

- **Manifest.** `mod.json` declares the mod's identity, its *settings* (persisted values with
  defaults), its *commands* (programs), its *lifecycle* (which commands Toolsy runs on its own and
  when), its *interface* (`ui`, the controls of its page), its *widgets* (tiles for Toolsy's
  dashboard) and its *localizations*.
- **State.** Each mod has one flat JSON object of state: its settings plus live values that
  commands report. The page and the tiles are a pure function of manifest and state: a control
  shows a state key, a template renders state into text, an expression decides on state whether a
  control is shown. Programs change what the user sees only by changing state.
- **Commands.** A command is a program started on demand: by a control (a button, a bound control
  with a `command`, a list row), by the lifecycle (the main switch, `refresh`, a system event) or as
  the long-lived `service`. Each command's standard output is a patch merged into the state.
- **Main switch.** A mod that declares `enable`, `disable` or `service` has an on/off switch;
  without any of them it is a passive mod that only shows its page and tiles.
- **Costs.** A mod that is off costs nothing. A mod that is on costs what it declares: its service,
  and its refresh while the panel is open (all the time with `background`).

The lifecycle of one interaction:

1. The user changes a control bound to a setting; Toolsy stores the new value in the state at once
   (and saves it, since it is a setting).
2. If the control names a `command`, Toolsy queues it with `TOOLSY_KEY` and `TOOLSY_VALUE` set.
3. The command runs; its patch is merged into the state; the page re-renders.
4. Toolsy then runs `refresh` (if the mod has one), whose patch reports the current truth.
5. A setting changed by the control or by the patch restarts the service, so it sees the new value.

## Procedure

### Understand the request

Restate the request as: what the user sees (page, tile, notification), what it changes on the Mac
(nothing, a setting, a process), how often it must be current, and which macOS tools provide the
data. Then decide:

| Situation | What to do |
| --- | --- |
| The request is clear and needs no root. | Build it. State your assumptions (refresh interval, defaults, wording) in the answer. |
| Two readings lead to materially different mods (a page vs. a tile, polling vs. an event, changing a system setting vs. only showing it). | Ask one short question naming both readings. If you cannot ask, build the one that changes less on the Mac and say so. |
| The data needs a network service, an account, an API key or a third-party program. | Ask whether that is acceptable. A mod MUST NOT send the user's data anywhere the user did not ask for, and MUST NOT download and run code. |
| It needs root (firewall rules, system files, other users' processes, `pmset`, `launchctl` in the system domain). | Ask for confirmation, then write a privileged mod following [Administrator privileges](#administrator-privileges): list each privileged command with the reason it needs root. |
| It would put user-typed text into a command run as root, run arbitrary commands the user types, weaken the Mac's security (disable SIP, Gatekeeper, the firewall, FileVault), read other apps' private data (passwords, messages, browser data), hide activity from the user, or act on other people. | Refuse that part, say why in one sentence, and offer the safe part (for example a page that shows the setting with a button that opens System Settings). |
| It needs something the format does not have: a window, an animation, a free-form layout, a text area, a file picker, a password field, drag and drop, sound, a global keyboard shortcut. | Say it is not possible and propose the nearest supported design (an `input` for a path, a `list` with commands, a notification). |

### Choose the shape

| Shape | Use it when | Manifest pieces | Switch |
| --- | --- | --- | --- |
| Passive page | It shows information read on demand. | `commands`, `lifecycle.refresh` (with `every` if it changes while the panel is open), `ui`. | none |
| Dashboard widget | One value is worth seeing at a glance with the other tiles. | `widgets` (with `value`, optionally a `gauge` or a `chart`, `detail` for quick controls), plus whatever keeps the value current: `refresh`, `events` (`launch` and `wake` for values that change rarely). | none, or any |
| Switch with a lasting effect | It turns something on that stays on by itself (a file flag, a system setting, a firewall rule). | `enable`, `disable`, `uninstall` (undo on removal), `refresh` that reports `enabled` so the switch follows the truth. | yes |
| Service | Something must run continuously while the mod is on: a process that holds an effect (`caffeinate`), or a stream of readings that must arrive while the panel is closed. | `lifecycle.service`; optionally `enable` and `disable` around it. | yes |
| Timer | Something happens at a wall-clock moment, possibly hours away. | Settings that hold the end time, a `service` that sleeps until it, `refresh` with `every: 1` for the countdown, the `wake` event to settle what ended during sleep. See [Timers that survive sleep](#timers-that-survive-sleep). | yes |
| Privileged | Only root can do the work. | One-shot commands with `"privileged": true`; everything else unprivileged. | usually yes |

How to keep a value current:

| The value changes… | Use |
| --- | --- |
| only when the user acts | the control's `command` (Toolsy runs `refresh` after it anyway) |
| while the user looks, every few seconds | `refresh` with `every` (seconds, at least 1) |
| when the Mac wakes, the network or the power source changes, or Toolsy starts | `lifecycle.events` (`wake`, `network`, `power`, `launch`); in a mod with a switch, only while it is on |
| continuously, and the mod must react while the panel is closed | a `service` |
| rarely, and the mod must notice it while the panel is closed, and no event fits | `refresh` with `every` of 60 or more and `"background": true` |

Widget or page: a widget is one headline (`value`) with at most one gauge or chart; give it a
`detail` when the user needs two or three controls right at the tile (a start button, a picker).
Everything else belongs on the page. A mod SHOULD always have a page (`ui`); without one Toolsy
shows only the status and summary.

### Scaffold

Start from the template closest to the shape. It writes a folder that already validates and works:

```sh
toolsy-mod new my-mod                       # basic: refresh, a stepper setting, a button
toolsy-mod new my-mod --template switch     # enable/disable a lasting effect, refresh reports enabled
toolsy-mod new my-mod --template service    # a service feeding a chart and the status
toolsy-mod new my-mod --template widget     # a dashboard widget with a gauge, detail, events, a notification
toolsy-mod new my-mod --name "My Mod" -o path/to/my-mod
```

The four templates are reproduced in [Worked examples](#worked-examples). Keep their structure:
`set -eu`, the `json_string` and `text` helpers, validation of every setting, one `printf` or `jq`
call that prints the whole patch.

### Write

1. **Manifest.** Pick the `id` (lowercase, it names the mod forever: an update MUST keep it), the
   settings with defaults of the type their control stores, the commands, the lifecycle, the page,
   the widgets. Every text the user sees is English; add the `ru` table (and others you are asked
   for) at the end, after the text is final.
2. **Scripts.** One script per mod with the action as its first argument (`"args": ["start"]`) is
   the idiom; each action prints one complete patch. Follow [Script craft](#script-craft).
3. **README.md** next to `mod.json`, for the user: what the mod does, a table *What it runs*
   (command, programs it starts, when), a section *What it never does* (no network, no root, which
   files it never touches), and how to try it with `toolsy-mod`.

### Verify

Run this loop after every change until each step gives the expected result. `toolsy-mod` runs
commands exactly as Toolsy does (same environment, working directory, standard input, timeout), so
what passes here works in Toolsy.

```sh
toolsy-mod validate my-mod
```

Expected: `OK <id> <version>` and no `warning:` line. Fix every error at the field it names.

```sh
toolsy-mod run my-mod read --locale en
toolsy-mod run my-mod read --locale ru
toolsy-mod run my-mod read --state '{"host": "example.com", "enabled": true}'
toolsy-mod run my-mod apply --key level --value 7
toolsy-mod run my-mod watch --for 5
toolsy-mod run my-mod changed --event network --json
```

Run every command at least once, with the settings' defaults and with realistic state (`--state`),
in English and Russian (`--locale`), as each control would start it (`--key`, `--value`), with the
event that starts it (`--event`), and the service for a few seconds (`--for`). Expected for each:
`result:  exit status 0`, `output:  a patch` (or `a patch` on every `line N:` of a service), no
`note:` saying something is ignored, and the patch holding exactly the keys the page reads. Then try
what can go wrong: an empty or odd setting (`--state '{"folder": ""}'`, a value with a quote, a
space, non-ASCII), a missing tool, an offline Mac; the command MUST fail with a clear message on
standard error (`error:   Toolsy shows "…"`) or report the situation in its patch, never print a
broken patch. Keep anything the command wrote with `--data <folder>` and look at it.

```sh
toolsy-mod preview my-mod
toolsy-mod preview my-mod --state '{"enabled": true, "count": 3, "status": "Ready", "level": "ok"}'
toolsy-mod preview my-mod --state '{"enabled": true, "rows": [], "error": "Cannot read the disk"}'
toolsy-mod preview my-mod --state '<the patch run printed>' --language ru
```

Preview the starting state (nothing reported yet), a typical state (paste the patch `run` printed
into `--state`), the empty state (empty lists, missing values) and the error state. Expected: every
template renders readable text (no stray `{{`, no empty label, a `default:` where a value may be
missing), every control you meant to hide is `[hidden]` exactly when it should be, every picker has
a `[selected]` option, and every widget has a non-empty value.

### Pack

```sh
toolsy-mod pack my-mod -o my-mod.toolsymod
toolsy-mod validate my-mod.toolsymod
```

Expected: `OK <id> <version> <path>` and then `OK <id> <version>`. Raise `version` whenever you
deliver a changed mod, so the user can tell versions apart.

### Deliver

Hand the user:

1. The folder, every file in full: `mod.json`, the scripts (executable), `README.md`.
2. The packed file `<id>.toolsymod`, if you could run the tool.
3. How to install: drop the `.toolsymod` file on the Toolsy menu bar icon or on the open panel, or
   press **+** in the panel and choose it, or double-click it. Installing a mod with the same `id`
   again updates it and keeps its settings.
4. In two or three sentences: what the mod runs and when (taken from the README's table), and what
   it never does. For a privileged mod, the list of commands that will run as root and why each
   needs root; Toolsy shows the same list in its installation confirmation.
5. What you verified (the commands you ran and their results) and what you could not (for example a
   power event you could only simulate with `--event power`).

### Without a shell

If you cannot run commands, deliver the same files and tell the user to run, in the folder's
parent:

```sh
T=/Applications/Toolsy.app/Contents/Helpers/toolsy-mod
chmod +x my-mod/scripts/*.sh
"$T" validate my-mod
"$T" run my-mod read
"$T" preview my-mod
"$T" pack my-mod -o my-mod.toolsymod
```

and to send you any output that is not `OK …`, contains `warning:`, `FAILED` or `note:`. Write the
files exactly as they must be on disk (each in a fenced block labelled with its path), say which
are executable, and do not claim the mod was tested. Be stricter with yourself than usual: check
every field name against the reference tables and every template and expression against their
grammar, since nothing will catch a mistake before the user does.

## Reference

### Files and packages

| Form | What it is |
| --- | --- |
| a folder | `mod.json` at its root plus every file the manifest names. What you write and test. |
| `<id>.toolsymod` | A zip archive of that folder, with `mod.json` at the archive's root or inside a single top-level folder. What the user installs. Made by `toolsy-mod pack`. |
| a lone `.json` file | A manifest without other files: possible only when every command is a `shell` command. |

Rules for the contents (installing refuses a mod that breaks one):

- Regular files and folders only: no symbolic links, no other special files.
- At most 2 000 files and 64 MB in total. `.DS_Store` files are skipped.
- Paths are relative, at most 512 bytes, each component at most 255 bytes, without `.` or `..`
  components, control characters or `\`. Two paths MUST NOT differ only by letter case.
- Executable bits are kept: every `exec` program MUST be executable (`chmod +x`) and SHOULD start
  with a `#!` line such as `#!/bin/sh`.
- The folder SHOULD be named after the mod's `id`. Installed, it lives in
  `~/Library/Application Support/Toolsy/Mods/<id>/` exactly as packed.

### Manifest

```json disk-free/mod.json
{
  "schema": 1,
  "id": "disk-free",
  "name": "Disk Free",
  "version": "1.0.0",
  "author": "Your Name",
  "summary": "Shows how much space is left on the startup disk",
  "icon": "internaldrive",
  "tint": "teal",
  "homepage": "https://example.com/disk-free",
  "settings": { "warnBelow": 20 },
  "commands": { "read": { "exec": "scripts/read.sh", "timeout": 10 } },
  "lifecycle": { "refresh": { "command": "read", "every": 60 } },
  "ui": [
    { "type": "value", "label": "Free", "value": "{{free|bytes|default:…}}", "tint": "{{level}}" },
    { "type": "stepper", "label": "Warn below", "bind": "warnBelow", "min": 5, "max": 100, "step": 5, "unit": " GB", "command": "read" }
  ],
  "localizations": { "ru": { "Disk Free": "Свободно на диске", "Shows how much space is left on the startup disk": "Показывает, сколько места осталось на загрузочном диске", "Free": "Свободно", "Warn below": "Предупреждать при", " GB": " ГБ" } }
}
```

| Field | Type | Required | Meaning |
| --- | --- | --- | --- |
| `schema` | number | yes | Always `1`. |
| `id` | string | yes | 1–64 of `a-z 0-9 . _ -`, starting and ending with a letter or digit. Identifies the mod: installing a mod with an installed `id` replaces that mod. |
| `name` | string | yes | Display name, 1–80 characters, not blank. Translated. |
| `version` | string | yes | Free form, 1–32 characters, such as `1.0.0`. |
| `author` | string | no | Shown on the mod's page. Not translated. |
| `summary` | string | no | One sentence under the name. Translated. |
| `icon` | string | no | An SF Symbol name, such as `bolt.fill`, `network`, `clock`, `internaldrive`. An unknown name shows no icon. |
| `tint` | string | no | The mod's accent colour, see [Colours](#colours). |
| `homepage` | string | no | An `http` or `https` URL with a host. |
| `settings` | object | no | Setting key → default value. See [State](#state). |
| `commands` | object | no | Command name → command. See [Commands](#commands). |
| `lifecycle` | object | no | Which commands Toolsy runs on its own. See [Lifecycle](#lifecycle). |
| `ui` | array | no | The controls of the mod's page. See [Interface](#interface). |
| `widgets` | array | no | Tiles for the dashboard. See [Widgets](#widgets). |
| `language` | string | no | The language the manifest's own text is written in, a code like the keys of `localizations`. Default `"en"`. MUST NOT also be a key of `localizations`. See [Localization](#localization). |
| `localizations` | object | no | Language → source text → translation. See [Localization](#localization). |

Unknown fields are ignored, at the top level and in every object below it. A manifest that breaks a
rule is refused with a message that starts with the path of the offending field
(`ui[2].children[0].when: …`).

### State

The state of a mod is one flat JSON object. Its keys MUST match `[A-Za-z_][A-Za-z0-9_]*` and be at
most 64 characters long (they become environment variable names).

- **Settings** are the keys declared under `settings`, with their defaults. Their values are saved
  whenever they change, by a control or by any patch, and survive restarts and updates. A saved value
  wins over the default; a setting a new version no longer declares is dropped. Give a setting the
  default of the type its control stores (see [Inputs](#inputs)).
- **Live state** is every other key. Commands report it. It is lost when Toolsy quits and when the
  mod is updated or reloaded, so every value the page shows SHOULD be reported again by `refresh`,
  an event command or the service.
- In a patch, `null` removes a key; for a setting that means its value is gone until something sets
  it again (the default is not restored).

Keys Toolsy reads itself:

| Key | Type | Meaning |
| --- | --- | --- |
| `enabled` | boolean | The main switch. Toolsy sets it after `enable` and `disable` succeed and saves it. A patch MAY set it to move the switch to the truth: Toolsy then starts or stops the service to match **without** running `enable` or `disable`. A value that is not `true` or `false` is ignored. |
| `status` | string | One short line under the mod's name in the list and on its page, such as `"Active"` or `"3 updates"`. Not shown when it is not a string. |
| `level` | `"ok"`, `"warn"`, `"error"`, `"off"` | Colour of the status: green, orange, red, grey. Any other value colours nothing. |
| `error` | string | A failure message shown on the mod until it is cleared (see [Errors](#errors)). Toolsy sets it when a command fails; a patch may set it (a non-empty string) or clear it (`null`, `""` or any non-string). |
| `notify` | string or object | Not state: a patch carrying it shows a system notification (see [Notifications](#notifications)) and the key is never stored. |

These five keys MUST NOT be declared under `settings`; inputs MUST NOT bind them; `capture` MUST
NOT name `enabled` or `notify`; nothing can bind or read `notify`. Displays and expressions may read
the other four (`"when": "enabled"`, `"tint": "{{level}}"`).

### Commands

```json
"commands": {
  "read":   { "exec": "scripts/disk.sh", "args": ["read"], "timeout": 10 },
  "apply":  { "exec": "scripts/disk.sh", "args": ["apply"], "stdin": true },
  "name":   { "shell": "/usr/sbin/scutil --get ComputerName", "capture": "computer" },
  "repair": { "exec": "bin/repair", "privileged": true, "timeout": 120 }
}
```

Command names: 1–64 letters, digits, `_` and `-`, starting with a letter or `_`.

| Field | Type | Default | Meaning |
| --- | --- | --- | --- |
| `exec` | string | | A file of the mod (relative path), started directly. It MUST be executable. Exactly one of `exec` and `shell` is required. |
| `shell` | string | | A script run as `/bin/sh -c '<script>' toolsy <args…>`. Not blank. |
| `args` | array of strings | `[]` | Arguments, passed literally, never through a shell. For `shell` they are `$1`, `$2`, … (`$0` is `toolsy`). |
| `stdin` | boolean | `false` | Send the [command input](#input) as one JSON document on standard input. Without it standard input is empty (`/dev/null`). |
| `timeout` | number | `30` | Seconds, more than 0 and at most 3600. When it runs out, the command and every process it started get `SIGTERM`, and `SIGKILL` 2 seconds later; the run counts as failed. Not applied to the service. Leave room: the first start of a program the Mac has not run before (a mod just installed or changed) can take seconds longer while macOS checks it. |
| `capture` | string | | A state key that receives the trimmed standard output as a string, instead of reading the output as a patch. A capturing command cannot set other keys or notify. |
| `privileged` | boolean | `false` | Run as root through Toolsy's helper. See [Administrator privileges](#administrator-privileges). |

#### Environment

A command runs with the mod's folder as its working directory and exactly these variables; nothing
else is inherited:

| Variable | Value |
| --- | --- |
| `TOOLSY_MOD_ID` | The mod's `id`. |
| `TOOLSY_MOD_DIR` | The mod's folder. Read it, never write to it. |
| `TOOLSY_DATA_DIR` | A folder the mod may write to, created before the command starts and kept across runs and updates; deleted when the mod is removed. |
| `TOOLSY_EVENT` | Why the command runs: `enable`, `disable`, `uninstall`, `refresh`, `service`, `command` (a control started it), or the system event `launch`, `wake`, `network`, `power`. |
| `TOOLSY_COMMAND` | The command's name. |
| `TOOLSY_KEY` | The state key of the control that started the command: the bound key of a toggle, slider, stepper, picker or input, the `bind` of a list whose row was clicked. Absent otherwise (a button sets none). |
| `TOOLSY_VALUE` | The control's new value, a button's `value`, or the clicked row's `id`, as text (`true`/`false`, `7`, `2.5`, the string itself). Absent when there is none. |
| `TOOLSY_LOCALE` | The language the mod is shown in, lowercase BCP 47: the first of the user's preferred languages the mod has text in, as the system names it (`ru`, `en-us`, `zh-hans-cn`, `ru-us`), or the manifest's `language` when it has text in none of them. Compare its first part, `${TOOLSY_LOCALE%%-*}`, so that what a command reports matches the page. |
| `TOOLSY_STATE_<key>` | One per state key whose value is a string, number or boolean, as text: strings as they are, whole numbers without a decimal point (`3`, not `3.0`), `true`/`false`. Keys holding arrays, objects or `null` have no variable. `TOOLSY_STATE_enabled` is the switch. |
| `PATH` | `/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin`; for privileged commands `/usr/bin:/bin:/usr/sbin:/sbin`. |
| `HOME`, `USER`, `LOGNAME`, `TMPDIR`, `SHELL` | The user's; for privileged commands root's (`HOME` is `/var/root`). |
| `LANG` | The user's, or `en_US.UTF-8` when Toolsy has none (it usually has none: apps started at login get no `LANG`). |

Toolsy never puts a value into a command line: user input cannot inject shell syntax unless the mod
itself evaluates it. The state is a snapshot taken when the command starts.

#### Input

With `"stdin": true` the command reads one JSON document:

```json
{ "event": "command", "command": "apply", "key": "level", "value": 7, "locale": "ru",
  "state": { "level": 7, "host": "example.com", "enabled": true } }
```

`key` and `value` are present only when a control started the command, `locale` only when
`TOOLSY_LOCALE` is set. `value` and `state` keep their JSON types, which the environment variables
cannot (arrays and objects are only here). Standard input is closed after the document.

#### Output

Standard output of a command that succeeds is read as one **patch**: a JSON object whose keys are
merged into the state.

```json
{ "free": 120394752000, "status": "112 GB free", "level": "ok", "volumes": [ { "title": "Macintosh HD", "value": "112 GB" } ] }
```

- Leading and trailing whitespace is ignored. Empty output changes nothing.
- Output that is not JSON, or JSON that is not an object (an array, a number), is ignored; no
  error is shown. Several objects in a row are not JSON. A one-shot command's patch may span
  several lines; a service's patch MUST be one line.
- Keys that are not valid state keys are ignored. `null` removes a key. A key whose value does not
  change re-renders nothing, so reporting everything every time is fine.
- Only the first 1 MB of standard output and of standard error is read; a longer patch is cut and
  therefore ignored.
- With `capture` the trimmed output is stored as a string under that key instead.

A command **fails** when it exits with a status other than 0, is killed by a signal, runs into its
timeout, or cannot be started. Its whole output is then discarded (a `notify` with it) and the
mod's `error` becomes, in this order: the `error` string of a JSON object on standard output, the
last non-empty line of standard error, or a generic message (`"read" failed: exit status 1.`). A
bound control that started the failed command keeps the value the user gave it.

#### Errors

`error` stays shown until one of these happens:

- the user dismisses it;
- a command the user started (the switch, a button, a bound control, a list row) succeeds without
  setting `error`;
- the error came from `refresh` or from the service, and that same source reports again without it;
- the error came from an event command, and an event command succeeds;
- any patch sets `error` to `null`, `""` or a non-string.

So the `refresh` that follows a failed button does not hide why the button failed, while a problem
found by `refresh` disappears as soon as `refresh` stops finding it.

#### Notifications

A patch (the output of a command or a line of the service) may carry `notify`:

```json
{ "status": "Connected", "notify": "Connected to Office VPN" }
```

```json
{ "notify": { "title": "Backup finished", "body": "42 files, 1.2 GB" } }
```

| Rule | |
| --- | --- |
| Form | A string (the body), or an object with `body` and optionally `title`. Without a title the mod's name (translated) is the title. A blank or missing body shows nothing. |
| Length | Trimmed; the title is cut to 80 characters and the body to 240, ending in `…`. |
| Rate | At most one notification per mod every 5 seconds, and an identical one (same title and body) within 60 seconds is dropped. Dropped means lost, not delayed. |
| Delivery | A banner without sound, grouped per mod, also while the panel is open. A click opens Toolsy's panel on the mod's page. |
| Permission | macOS asks the user the first time any mod notifies. If the user refused, notifications are dropped without an error. |
| Failure | A failed command's patch is discarded, its `notify` with it. A `capture` command cannot notify. |

Notify about events the user wants to hear of (a phase ended, a change happened while they were
away), not on every refresh: an unchanged notification is dropped anyway, but a changing one every
few seconds is noise.

#### Order

The commands of one mod never overlap: Toolsy queues them and runs one after another in the order
they were started. The service is not a queued command: it runs in parallel with them. While a
command runs or waits, every button that runs it shows a spinner; a slow command delays every
command after it, including `refresh`. A `refresh` or event command that is already waiting is not queued
again; repeated runs of a `live` slider's command collapse into the newest value.

### Lifecycle

```json
"lifecycle": {
  "enable": "start",
  "disable": "stop",
  "uninstall": "cleanup",
  "service": "watch",
  "refresh": { "command": "status", "every": 10, "background": false },
  "events": { "wake": "status", "network": "status" }
}
```

Every value names a command of `commands`.

| Hook | When it runs | Rules |
| --- | --- | --- |
| `enable` | The user switches the mod on (the main switch). | On success `enabled` becomes `true`, unless its patch sets `enabled` itself (a patch with `"enabled": false` refuses to switch on, without an error). On failure the switch returns to off and the error is shown. |
| `disable` | The user switches the mod off, and before removal when the mod is on. | Runs after the service has been stopped. On success `enabled` becomes `false` (unless its patch sets it). On failure the switch stays on and the service is started again. MUST succeed when there is nothing to undo. |
| `uninstall` | The mod is being removed, after `disable`, whether the mod was on or off. | Undo what the mod left on the Mac outside its data folder. If it fails, the removal stops and the mod stays installed. MUST succeed when there is nothing to undo. |
| `service` | Started when the mod is switched on (after `enable` succeeds), when Toolsy starts with the mod on, and after a crash. | See [Service](#service). |
| `refresh` | When the panel opens; after every other command of the mod finishes (including after `enable`, `disable` and event commands, panel open or not); every `every` seconds while the panel is open. | `command` (required), `every` (seconds, at least 1; without it no schedule), `background` (`true`: the schedule also runs while the panel is closed, as long as the mod is on, or always for a mod without a switch). Never at launch by itself: use the `launch` event for that. |
| `events` | Something happens to the Mac. | See [System events](#system-events). |

- A mod has a main switch if it declares `enable`, `disable` or `service`. Without one it is
  passive: its refresh, events and widgets always work, and `enabled` is always `false`.
- `enable` and `disable` run only when the user flips the switch (or removes the mod), never when
  Toolsy starts or quits. An effect that must be re-established after a restart of the Mac is kept
  by a `service`; an effect that persists by itself (a file flag, a system setting) is reported by
  `refresh` with `enabled` in its patch, so the switch shows the truth.
- A button whose command sets `enabled` in its patch switches the mod like the main switch, without
  `enable`/`disable` running; the service follows.
- On an update (installing the same `id` again) the service of the old version is stopped and that
  of the new one started; no hook runs, and the switch keeps its position.

#### Service

- It starts with `TOOLSY_EVENT=service` and the state of that moment, and receives the
  [input](#input) on standard input if it sets `stdin`.
- Every line it prints on standard output is a patch, applied at once. Blank lines are ignored;
  a line longer than 256 KB is dropped.
- It is restarted (stopped, then started with the new state) when a setting changes by a control or
  by a command's patch, once the changes have settled; so it reads settings once, at its start. A
  setting the service's own patch changes is saved but does not restart it.
- It is stopped with `SIGTERM` to its process group, and `SIGKILL` 2 seconds later: before `disable`
  runs, when a patch sets `enabled` to `false`, for an update, and when Toolsy quits.
- Exit status 0 switches the mod off as if the user had (`disable` runs). Any other exit restarts it
  after 1, 2, 4, … up to 60 seconds and shows the last line of standard error as the error; the delay
  starts again from 1 after it has run for 30 seconds.
- It MUST NOT be `privileged`, MUST NOT use `capture`, and MUST NOT also be the refresh command or an
  event command.
- It runs in parallel with the mod's commands. When a command and the service can both report the
  same transition (a phase ending), both MUST compute the same patch from the same inputs, so the
  result does not depend on which runs first (and an identical notification is dropped).

#### System events

`events` maps an event to the command that answers it, run with `TOOLSY_EVENT` set to the event:

| Event | When it is posted |
| --- | --- |
| `launch` | Toolsy started (usually at login) and loaded the mods. |
| `wake` | The Mac woke from sleep. |
| `network` | The primary interface or its router changed, or the addresses of any interface changed (also one that is not primary, such as a VPN with a split tunnel). Link-local addresses (`fe80::`) do not count. Posted about 2 seconds after the network has settled: a burst of changes is one event. Temporary IPv6 addresses, which the system replaces about once a day on the same network, do not count either. |
| `power` | The Mac changed between the power adapter and the battery (or a UPS). Not on charge changes. |

- An event command runs only while the mod is on (always, for a mod without a switch).
- It is queued like any command; if that command is already waiting, the event does not queue it
  again. `refresh` runs after it.
- A privileged event command is skipped silently while the mod lacks administrator access.
- Something that happens while the Mac sleeps is not replayed after it wakes; answer `wake` and
  read the current state then.
- Toolsy observes an event only while some installed mod declares it.

### Interface

`ui` is an array of controls. Each control is an object with a `type` and the fields of its type.
Three optional fields work on every control:

| Field | Type | Meaning |
| --- | --- | --- |
| `when` | expression | The control is shown only while it is true. A section or row whose children are all hidden is hidden too. |
| `disabled` | expression | The control is greyed out and inert while it is true. |
| `help` | plain text | A tooltip, and the hint VoiceOver reads. Not a template. |

Fields marked *template* below may contain `{{…}}` placeholders ([Templates](#templates)); all other
text fields are shown exactly as written, braces included. Fields in **bold** are required.

How the page is laid out: each top-level `section` is a separate rounded group with its title;
consecutive top-level controls that are not sections form one untitled group; a top-level `divider`
ends such a group and is not drawn itself. Inside a section, controls are stacked, and a `divider`
draws a line.

#### Layout

| Type | Fields |
| --- | --- |
| `section` | `title` (template), `footer` (template, small text under the group), **`children`** (array of controls), `collapsible` (`true`: the user can fold it; needs `title`), `collapsed` (`true`: starts folded; needs `"collapsible": true`). |
| `row` | **`children`**: 1–4 controls side by side with equal widths. No `section` or `row` inside. Meant for `stat`s and buttons. |
| `divider` | No fields. |

Controls nest at most 4 levels deep (a widget's `detail` counts as level 2), and a manifest holds
at most 200 controls in `ui` and all widgets' `detail` together.

#### Inputs

| Type | Fields | Stores |
| --- | --- | --- |
| `toggle` | **`label`** (template), `icon`, **`bind`**, `command` | `true` or `false` |
| `slider` | **`label`** (template), `icon`, **`bind`**, **`min`**, **`max`** (`min` < `max`), `step` (positive), `unit` (suffix shown after the number, such as `"%"` or `" ms"`), `command`, `live` (`true`: run the command while dragging; otherwise once on release) | a number |
| `stepper` | **`label`** (template), `icon`, **`bind`**, `min`, `max` (`min` < `max` when both), `step` (positive, default `1`), `unit`, `command` | a number |
| `picker` | `label` (template), `icon`, **`bind`**, exactly one of **`options`** (1–32 options) and **`optionsFrom`** (a state key), `style` (`"segmented"` or `"menu"`; default: segmented up to four options, a menu beyond), `command` | the chosen option's `value`, with its type |
| `input` | `label` (template), `icon`, **`bind`**, `placeholder`, `command` (runs when the text is committed: Return or leaving the field) | always a string, even when the setting's default is a number |
| `button` | **`label`** (template), `icon`, exactly one of `command`, `open` (an `http`/`https` URL opened in the browser) and `copy` (template: clicking copies the rendered text, line breaks included), `value` (any JSON value handed to the command as `TOOLSY_VALUE`), `style` (`"normal"` default, `"prominent"`, `"destructive"`), `confirm` (a question the user must confirm first; plain text) | nothing |

- A control with `bind` reads that state key and writes the user's change to it at once (a
  declared setting is saved). With `command`, that command runs next with `TOOLSY_KEY` and
  `TOOLSY_VALUE` set.
- Inputs MUST NOT bind `enabled`, `status`, `level`, `error` or `notify`. Use the main switch, or a
  button whose command sets `enabled`.
- A bound value of the wrong type (or a missing one) shows as: toggle off, slider at its `min`,
  stepper at 0 moved into its range, picker with nothing selected, input empty (for an array or
  object).
  `toolsy-mod validate` warns when a setting's default does that.
- A picker option is `{ "value": …, "label": "…", "icon": "…" }` with a string, number or boolean
  `value` (`label` defaults to the value as text; `icon` optional), or a bare string that is both
  value and label. The value `"1"` is not the value `1`.
- With `optionsFrom`, the options are read from that state key, which a command fills with an array
  of the same elements. Elements of another shape are skipped, as is a value that already came
  before it (an option is known by its value), and only the first 32 are used. Until
  the key holds an array with at least one option, the picker shows an inert "No options" capsule.
  When the bound value is none of the options, nothing is selected; the value is kept.

#### Displays

| Type | Fields | Shows |
| --- | --- | --- |
| `value` | **`label`** (template), **`value`** (template), `icon`, `tint` (template), `copyable` (`true`: a click copies the value) | a "label … value" line |
| `stat` | **`label`** (template), **`value`** (template), `icon`, `tint` (template) | a caption over a value; meant for `row`s |
| `text` | **`text`** (template; may contain `\n`), `style` (`"body"` default, `"caption"`, `"title"`, `"mono"`), `tint` (template) | free text |
| `gauge` | **`label`** (template), `icon`, **`bind`** (a number), `min` (default `0`), `max` (default `100`; `min` < `max`), `unit`, `format`, `style` (`"bar"` default, `"ring"`), `tint` (template) | a number against a range |
| `chart` | `label` (template), **`series`** (1–6 of `{ "bind", "label", "tint" }`, `bind` required), `style` (`"line"` default, `"area"`, `"bar"`), `points` (2–600, default 60), `min`, `max` (fixed axis bounds; fitted to the data when absent; `min` < `max`), `unit`, `format` | numbers over time |
| `list` | **`bind`** (an array), `command` (runs when a row is clicked), `empty` (plain text shown while the array is empty), `limit` (positive: at most this many rows) | rows |

- `format` is a filter chain as it would follow `|` in a template (`"bytes"`, `"rate"`,
  `"fixed:1"`, `"div:1000|fixed:1"`). When set, the readouts show the number through it instead of
  the number followed by `unit`. `unit` and `format` are plain text, not templates.
- A gauge whose key holds no number shows an empty bar and `—`; a number outside `min`…`max` is
  drawn at the nearer end.
- A chart series bound to a **number** records that number each time a patch contains the key
  (also when it is unchanged) and plots the last `points` samples; history starts empty when Toolsy
  starts. A series bound to an **array of numbers** plots the array as it is (non-numbers skipped).
  Series without `tint` get distinct colours.
- A list row is an object `{ "title", "subtitle", "value", "icon", "tint", "id" }` (`title`
  required and not empty; `value` is shown at the right; `id` defaults to the title) or a bare
  string or number (the title). Other elements are skipped. A row click runs the list's `command`
  with `TOOLSY_KEY` = the list's `bind` and `TOOLSY_VALUE` = the row's `id` as a string; the id is
  all the command learns about the row, so give every row of a list with a `command` a unique `id`
  the command can validate (`"635:8080"`, not the title).
- A `list` has no label: put a `text` with `"style": "caption"` above it.

#### Colours

`tint` takes a colour name (`red`, `orange`, `yellow`, `green`, `mint`, `teal`, `cyan`, `blue`,
`indigo`, `purple`, `pink`, `brown`, `gray`), a level (`ok`, `warn`, `error`, `off`) or `#RRGGBB`.
Anything else (and an empty result) leaves the default colour. Where `tint` is a template,
`"tint": "{{level}}"` follows the mod's status and `"{{up|either:green:red}}"` chooses by state.

### Widgets

A mod may offer up to 8 tiles for Toolsy's dashboard. A tile shows a caption, one headline value
and optionally a small chart or a level bar, like the built-in CPU and memory tiles.

```json
"widgets": [
  {
    "id": "latency", "title": "Ping", "icon": "dot.radiowaves.left.and.right",
    "value": "{{ms|fixed:0|default:—}} ms", "tint": "{{level}}", "size": "small",
    "chart": { "series": [ { "bind": "ms" } ], "style": "area", "points": 30, "min": 0 },
    "when": "enabled",
    "detail": [ { "type": "input", "label": "Host", "bind": "host" } ]
  }
]
```

| Field | Type | Default | Meaning |
| --- | --- | --- | --- |
| `id` | string | required | 1–32 of `a-z 0-9 _ -`, starting with a letter or digit, unique in the mod. Names the tile in the user's layout: keep it across versions. |
| `title` | template | the mod's name | The caption. An empty result shows the mod's name. |
| `icon` | string | the mod's icon | SF Symbol name. |
| `value` | template | required | The headline. MUST NOT be blank. Give it a `default:` for the time before the first report. |
| `tint` | template | the mod's tint | A [colour](#colours). |
| `size` | string | `"small"` | Columns of the three-column dashboard the tile takes: `"small"` 1, `"medium"` 2, `"wide"` 3. The user can change it. |
| `chart` | object | | A sparkline under the value: **`series`** (1–3 of `{ "bind", "label", "tint" }`), `style` (`"line"`, `"area"` default, `"bar"`; the user can change it), `points` (2–120, default 30), `min`, `max` (`min` < `max`). Series record history like a chart's. |
| `gauge` | object | | A level bar under the value: **`bind`** (a number), `min` (default 0), `max` (default 100), `min` < `max`. |
| `detail` | array | | Controls shown under the tile when the user expands it, laid out like the page; they count toward the 200 controls. The expanded tile always ends with a row that opens the mod's page. Without `detail`, a click on the tile opens the page. |
| `when` | expression | | The tile is on the dashboard only while it is true. |

- A widget has at most one of `chart` and `gauge`.
- When a mod is installed for the first time, its widgets are added at the end of the dashboard.
  An update or a reinstall adds none and re-adds none the user removed; the user switches each
  widget on and off on the mod's page, or in the dashboard's editor.
- While a mod with a switch is off, its tiles are dimmed and keep their last values.
- The tile's value is rendered from state like any template: keep it short (it has the width of
  one column when `small`), and make sure something reports it soon after launch (`launch` event or
  the service) if it must be right before the panel is first opened.

### Localization

```json
"localizations": {
  "ru": { "Keep the display on": "Не выключать дисплей", "Now": "Сейчас", "{{ms}} ms": "{{ms}} мс" }
}
```

| Rule | |
| --- | --- |
| Languages | Keys are lowercase language codes `[a-z]{2,3}`, optionally with one more subtag: `ru`, `de`, `pt-br`, `zh-hans`. At most 20 languages. |
| Entries | Source text, exactly as written in the manifest (spaces, placeholders and filters included), → translation. At most 500 entries per language. Text without an entry stays as written. |
| Choice | Toolsy goes through the user's preferred languages in order and stops at the first the mod has text in: the manifest's own `language` (`"en"` unless stated), for which the manifest is shown as written, or a table, the most specific first (for `pt-BR` it takes `pt-br`, otherwise `pt`; for `ru-RU`, `ru`). A user who prefers English and then Russian reads an English mod in English, whatever tables it has. Without a match the manifest is shown as written. |
| The manifest's language | Write the manifest in English. When it must be written in another language, state it: `"language": "ru"`, and translate into English with an `en` table. A table for the manifest's own language is refused. |
| Translated | `name`, `summary`, and in controls and widgets: `label`, `title`, `footer`, `text`, `value`, `placeholder`, `confirm`, `empty`, `unit`, `help`, `copy`, option labels, chart and series labels, widget `title` and `value`. |
| Not translated | `id`, `author`, commands, `bind`s, keys, icons, tints, `format`, expressions, option values, a button's `value`, and anything a command reports. |
| Templates | A template is translated as a whole string before it is rendered: `"{{ms}} ms"` → `"{{ms}} мс"`. The translation MUST keep the same placeholders and stay a valid template; each table is checked at install like the text it replaces. Texts inside filters (`default:`, `either:`, `join:`) are part of the source string and are translated with it. |

Commands localise what they report (`status`, list rows, notifications) themselves with
`TOOLSY_LOCALE`. Every translated text SHOULD have an entry in every table, also when the
translation is identical (`"macOS": "macOS"`), so a missing entry is visibly a mistake.
`toolsy-mod validate` warns about an entry whose source text no field has. A mod added to the
`Mods/` folder of Toolsy's own repository MUST have a `ru` table with an entry for every text that
contains words, placeholders kept: the repository's tests check it.

### Templates

`{{path}}` is replaced by the state value at `path`, rendered as text: strings as they are, whole
numbers without a decimal point, other numbers in full (`2.5`), `true`/`false`, nothing for a
missing key or `null`, arrays and objects as compact JSON. Text outside `{{ }}` is literal;
`}}` without a matching `{{` is an error. Spaces around the path and the filter names are ignored.

A **path** is a state key followed by steps separated by `.`: `{{disk.free}}`, `{{rows.0.title}}`.
Each step (1–64 of `A-Z a-z 0-9 _`) indexes an object by key or an array by a non-negative
integer. A step that finds nothing makes the whole value missing. `[0]` is not path syntax.

Filters follow `|` and apply left to right: `{{ping|fixed:1|default:—}}`.

| Filter | Takes | Gives |
| --- | --- | --- |
| `bytes` | number of bytes | decimal units, at most one decimal: `512 B`, `1.5 GB`, `12 MB` |
| `rate` | bytes per second | `1.2 MB/s` |
| `bitrate` | bytes per second | bits: `12.4 Mbit/s` (`bit/s`, `kbit/s`, `Mbit/s`, `Gbit/s`) |
| `percent` | number 0–100 | rounded: `42%` |
| `duration` | seconds | the two largest units: `45s`, `3m 20s`, `2h 05m`, `1d 4h`. The same in every language. |
| `round` | number | the nearest whole number (`2.5` → `3`) |
| `fixed:N` | number | exactly N decimals, N from 0 to 10: `fixed:1` → `23.5` |
| `number` | number | digits grouped for the user's locale, at most 2 decimals: `1,234.5`, `1 234,5` |
| `time` | Unix seconds | short time of day in the user's locale and time zone: `13:33`, `1:33 PM` |
| `date` | Unix seconds | short numeric date: `16.11.2025`, `11/16/2025` |
| `ago` | Unix seconds | relative time in the user's language: `5 min. ago`, `now`, `in 1 min.`, `3 days ago` |
| `mul:N` | number | the number times N (`mul:8`, `mul:0.5`) |
| `div:N` | number | the number divided by N (`div:1000`); N MUST NOT be 0 |
| `add:N` | number | the number plus N (`add:-273.15`) |
| `upper` | string | upper case |
| `lower` | string | lower case |
| `truncate:N` | string | cut to N characters (1–500) ending in `…`; shorter text unchanged |
| `count` | array, object or string | number of elements or characters |
| `join:SEP` | array | the string, number and boolean elements joined by SEP; `join` alone joins with `, ` |
| `either:A:B` | anything | A when the value is truthy (as in [expressions](#expressions)), otherwise B; B may be empty and may contain `:` |
| `default:TEXT` | anything | TEXT when the value is missing, `null` or renders as empty text; otherwise the value |

- Each filter acts only on the kind of value it is made for and passes anything else through
  unchanged. A numeric string such as `"12"` is not a number: report numbers as JSON numbers.
- Missing values pass through numeric filters as missing, so `{{ping|fixed:1|default:—}}` shows `—`
  until the first measurement. Put `default` last.
- A filter that produces text ends the numeric part of a chain: `{{x|percent|round}}` rounds
  nothing; write `{{x|round|percent}}`.
- Arithmetic that overflows renders nothing.
- The texts of `default`, `join` and `either` are kept exactly as written, spaces included
  (`{{a|default: n/a }}` gives ` n/a `), and cannot contain `|` or `}}`.
- `N` of `mul`, `div`, `add` is a plain decimal (`-273.15`, `0.5`), no exponent.
- `time`, `date`, `ago` and `number` follow the user's language and region; `duration`, `bytes`,
  `rate`, `bitrate` and `percent` do not. A mod that needs a localised duration formats it in its
  script (`"Ещё 1 ч 05 мин"`) and reports it as text.
- There is no "now" in templates or expressions. A countdown is computed by a command from the wall
  clock (`date +%s`) and refreshed with `every: 1` while the panel is open.
- An unknown filter, a missing or bad argument, or an argument to a filter that takes none is an
  error at install time naming the field.

### Expressions

`when` and `disabled` (of controls and widgets) are boolean expressions over the state:

```text
enabled
!enabled
mode == 'manual' && level >= 3
(status == "Active" || retries < 5) && !error
used / total * 100 > 80
name contains 'Air' && rows.0.title != null
count % 2 == 1
```

| Element | Syntax |
| --- | --- |
| state value | a key or a path (`disk.free`, `rows.0.title`); a missing value is `null` |
| number | `3`, `0.5`, `-1` (a `-` right before a digit starts a negative number unless it follows a value) |
| string | in `'single'` or `"double"` quotes, no escape sequences |
| literals | `true`, `false`, `null` |
| grouping | `( … )` |

Operators, loosest first (each level binds less tightly than the next):

1. or: `||`, true when either side is true.
2. and: `&&`, true when both sides are.
3. not: `!`, negates everything up to the next `&&` or `||`: `!a == b` means `!(a == b)`.
4. comparison: `==`, `!=`, `<`, `<=`, `>`, `>=`, `contains`. At most one per level without
   parentheses: `1 < a && a < 3`, never `1 < a < 3`.
5. sum: `+`, `-`, left to right.
6. product: `*`, `/`, `%` (the remainder, with the sign of the left side), left to right.

- A bare value is true unless it is missing, `null`, `false`, `0`, `""`, `[]` or `{}`.
- `==` and `!=` compare any values, types included: `count == "3"` is false when `count` is the
  number 3. `<`, `<=`, `>`, `>=` are true only between two numbers.
- Arithmetic works on numbers only; with anything else, or dividing (or taking the remainder) by
  zero, the result is `null`, which stays `null` through further arithmetic.
- `a contains b` is true when `a` is a string containing the string `b` (case-sensitive), or an
  array with an element equal to the string, number or boolean `b`; otherwise false.
- Only numbers can be negated: write `0 - a`, not `-a`.
- `true`, `false`, `null` and `contains` cannot be used as state keys in expressions.
- An expression that does not parse is an error at install time; nothing else is checked: a key
  that nothing sets is simply `null`. Make sure every key an expression reads is a setting or is
  reported by a command.

### Administrator privileges

A command with `"privileged": true` runs as root through Toolsy's helper, without a password
prompt each time:

1. The first time a mod with privileged commands is installed, Toolsy installs its helper; macOS
   asks for the administrator password then, and only then.
2. Installing the mod approves it: the confirmation lists the privileged commands, and the helper
   stores a copy of exactly the files being installed in a folder only root can read.
3. The helper runs privileged commands only from that copy. If the installed files change, the
   mod's privileged commands are refused until the mod is installed again from a package.

Rules for a privileged mod:

- Use `"privileged": true` only for the commands that need root; read status, show settings and
  everything else with unprivileged commands.
- Only one-shot commands can be privileged. The service MUST NOT be privileged; a privileged
  `refresh` or event command is skipped silently while the mod lacks access.
- Standard input and every `TOOLSY_*` variable (`TOOLSY_LOCALE` and `TOOLSY_STATE_*` included) are
  data from a user-level process that the program acts on as root: validate each against an
  allow-list (an exact set of words, digits only, a strict pattern) before use, and fail on anything
  else. MUST NOT put user-typed text into a command line, a file path outside the mod's data folder,
  a configuration file or a rule set, even quoted.
- `TOOLSY_MOD_DIR` is the root-owned copy and `TOOLSY_DATA_DIR` a root-owned folder
  (`/Library/Application Support/Toolsy/Data/<id>/`) that unprivileged commands cannot read.
- `PATH` holds system folders only: call every tool by absolute path, or ship it in the mod.
- MUST NOT write into the mod's own folder: a mod whose files change loses its privileged commands.
- A privileged command that has started runs to its end even if Toolsy quits; while it runs the
  mod cannot be updated or removed. Keep it short and give it a `timeout`.
- MUST NOT download or run code from the network, and MUST NOT install launch daemons, change
  security settings or touch other users' data.
- The README MUST list every privileged command, what it changes and why it needs root.

`toolsy-mod run` never runs anything as root. A privileged command is refused unless you pass
`--as-user`, which really runs it, as yourself with root's environment: use it to test input
validation and status checks. MUST NOT use it on a command that changes the system when it runs as
the user (most root operations simply fail without root, but not all of them).

### What Toolsy does around a mod

- **Installing.** The user drops the `.toolsymod` file on the menu bar icon or the panel, presses
  **+** and chooses it (or a mod folder, or a lone manifest), or double-clicks the file. Toolsy runs every check of
  `toolsy-mod validate`, shows a confirmation (with the privileged commands, if any) and installs.
  Installing an `id` that is installed replaces it, keeping its settings and switch position.
- **Removing.** From the mod's page. Toolsy runs `disable` (if the mod is on), then `uninstall`,
  then deletes the mod's folder, its saved settings and its data folder.
- **At login and quit.** Toolsy starts at login, loads the mods, starts the services of mods that
  were on and posts `launch`. When it quits it stops every service; no hook runs. If Toolsy crashed,
  the next launch stops the services the crashed instance left running before starting new ones.
- **The panel.** The panel opens from the menu bar icon. Opening it runs every mod's `refresh`;
  refresh schedules without `background` run only while it is open. The dashboard shows built-in
  tiles and mod widgets; below it is the list of mods, each with its switch and status, opening its
  page.
- **Developer mode** (a switch in Toolsy's settings): Toolsy watches the installed mods folder.
  Editing `mod.json` there reloads the mod (keeping its settings); editing another file restarts its
  running service; a folder added by hand is loaded. Each mod's page then ends with a Reload button,
  its folder, and its 20 most recent runs with their outcome and the end of standard error. Editing
  an installed privileged mod in place loses its administrator access, as always.

### Limits

| Limit | Value |
| --- | --- |
| Files in a mod | 2000 |
| Total size of a mod | 64 MB |
| `id` | 1–64 characters |
| `name` | 1–80 characters |
| `version` | 1–32 characters |
| State keys and command names | 64 characters |
| Command `timeout` | 30 s by default, at most 3600 s |
| Grace between `SIGTERM` and `SIGKILL` | 2 s |
| Standard output and standard error read per command | 1 MB each |
| One line of the service | 256 KB |
| `refresh.every` | at least 1 s |
| Controls in `ui` and all widgets' `detail` together | 200 |
| Nesting of controls | 4 levels |
| Children of a `row` | 1–4 |
| Options of a picker | 32 |
| Series of a chart / of a widget chart | 6 / 3 |
| Points of a chart / of a widget chart | 2–600, default 60 / 2–120, default 30 |
| Widgets per mod | 8 |
| Languages / entries per language | 20 / 500 |
| Notification title / body | 80 / 240 characters |
| Notifications per mod | 1 every 5 s; identical ones 1 per 60 s |

### toolsy-mod

`/Applications/Toolsy.app/Contents/Helpers/toolsy-mod` writes, checks, runs and packs mods without
the app. `<mod>` is a folder, a `.toolsymod` file or a lone manifest (`.json`); `<folder>` only a
folder. `toolsy-mod help <command>` explains each command. Options may come before or after the
positional arguments, as `--option value` or `--option=value`; an unknown, repeated or malformed
option is an error.

| Command | What it does | Prints |
| --- | --- | --- |
| `new <id> [--template <template>] [--name <name>] [-o <folder>]` | Writes a new mod folder (`./<id>` unless `-o`) that validates and works as it is: `mod.json`, one script, `README.md`. Never overwrites anything. Templates: `basic` (the default), `switch`, `service`, `widget`. The default name is made from the id (`my-mod` → `My mod`). | `OK <id> <folder>`, the files, a next step |
| `validate <mod> [--json]` | Every check installing runs, then [warnings](#warnings). | `OK <id> <version>` on standard output, or the error on standard error; then each warning on standard error after `warning: ` |
| `run <folder> <command> [options]` | Validates the mod and runs one command exactly as Toolsy does, then reports what Toolsy would make of it. Takes a folder only. | a report, see below |
| `preview <mod> [--state <json>] [--language <code>]` | Validates the mod and prints what its page and widgets show for a state, as an outline. Runs nothing. | the outline |
| `pack <folder> [-o <file.toolsymod>]` | Validates the folder and writes the package (`./<id>.toolsymod` unless `-o`), without `.DS_Store`, executable bits kept, replacing an existing file. | `OK <id> <version> <file>` |
| `help [<command>]` | Explains a command; without one, lists them. | to standard output |

Exit status: `0` success; `1` the mod or the run failed (a validation error, a command that exited
with another status, timed out or could not start, a service that exited with a status other than
0); `2` the tool was used wrongly: an unknown command or option, a missing or malformed argument, a
command the mod does not have, a privileged command without `--as-user`, `--for` for a command that
is not the service, `run` on something that is not a folder, `preview --language` for a language
the mod has no table for. `toolsy-mod` without arguments prints the overview to standard error and
exits with 2; `toolsy-mod help` prints it to standard output and exits with 0. Usage errors print
`toolsy-mod: <message>` and the command's synopsis on standard error.

`validate --json` prints one object instead: `{"ok": true, "id", "version", "name", "commands",
"privilegedCommands", "widgets", "languages", "warnings"}` (commands and languages sorted, widgets in
order), or `{"ok": false, "error"}`.

#### Options of run

| Option | Meaning |
| --- | --- |
| `--state <json>` | A JSON object merged over the starting state (the settings' defaults and `"enabled": false`); `null` removes a key. `enabled` must be a boolean; `notify` is refused. |
| `--key <key>` | `TOOLSY_KEY`. Needs `--value`. When an input control binds the key, the value is stored in the state first, as the control does. |
| `--value <json>` | `TOOLSY_VALUE`, as JSON: `7`, `true`, `'"some text"'`. Alone, it is a button's `value`. |
| `--event <event>` | `TOOLSY_EVENT`: `enable`, `disable`, `uninstall`, `refresh`, `service`, `command`, `launch`, `wake`, `network`, `power`. Default: `service` for the service command, `command` otherwise. |
| `--locale <code>` | `TOOLSY_LOCALE`, such as `ru` or `en-us`. Default: the language Toolsy shows the mod in on this Mac. |
| `--data <folder>` | `TOOLSY_DATA_DIR`. Default: a new temporary folder, removed after the run. |
| `--for <seconds>` | The service only: how long it runs before it is stopped as Toolsy stops it (default 5). |
| `--as-user` | Runs a privileged command as yourself with root's environment. Required for privileged commands; refused for others. |
| `--json` | Prints the report as one JSON object (`ok`, `exitStatus`, `timedOut`, `seconds`, `output` with `kind` `patch`, `capture`, `empty`, `notAnObject` or `notJSON`, `lines` for a service, `error`, `notes`, `stderr`, …). |

The text report has one labelled line per fact: `command:`, `event:`, `locale:`, `key:`, `value:`,
`stdin:` (what standard input carried), `data:`, `result:` (`exit status 0 after 0.02 s`,
`FAILED: exit status 1 …`, `FAILED: timed out …`, `FAILED: could not start the program`, for a
service `still running after 5 s, then stopped …`), `error:` (`Toolsy shows "…"`), `output:` (`a
patch, merged into the mod's state:` followed by the patch, `captured as text into "key": …`,
`empty, which changes nothing`, `ignored, not JSON (…)`, `ignored, JSON but not an object: …`, or for
a service `N lines, each applied at once:` and `line N: …`), `toolsy:` (what a host key in the patch
does), `notify:` (the notification that would appear), `note:` (anything Toolsy ignores or does
besides: an invalid key, a setting saved, a service restarted, the mod switched off) and `stderr:`.

`preview` prints one line per control, indented by nesting: its type, its rendered text, its bound
value (`bind key = value` or `bind key missing`), `[hidden]` when `when` is false (or nothing inside
a section or row is shown), `[disabled]`, a picker's options with `[selected]`, a list's rows, a
chart's series; then each widget with its title, value, size, gauge or chart and detail.

#### Warnings

A warning is something valid that almost always is a mistake. It does not change the exit status;
fix it anyway.

| The tool says | Meaning and fix |
| --- | --- |
| `commands.<name>: shell starts with "<word>", which is not a file of the mod` | The script runs a file of the mod that does not exist. Fix the path, or use `exec`. |
| `commands.<name>: shell starts with "<word>", which is not executable (chmod +x)` | `chmod +x` the file. |
| `<control path>: the default of setting "<key>", <value>, is not true or false; the toggle shows it as off` | A toggle's setting MUST default to `true` or `false`. |
| `<control path>: the default of setting "<key>", <value>, is not a number; the slider shows its minimum` (or `stepper`) | Default a number. |
| `<control path>: the default of setting "<key>", <value>, is below the slider's min <min>` (or `above the … max`) | Default inside the range. |
| `<control path>: the default of setting "<key>", <value>, matches the value of none of the options (<values>); the picker shows nothing selected` | Default to one of the options' values, with the same type. |
| `<control path>: the default of setting "<key>", <value>, is not text, a number or a boolean; the field shows nothing` | An input's setting defaults to a string. |
| `localizations.<code>: "<text>" is not the text of any translated field, so this entry is never used` | The source text was edited or misspelt after it was translated: copy it again exactly. |

## Script craft

### Language

Write scripts in POSIX `sh` (`#!/bin/sh`; on macOS it is bash 3.2 in POSIX mode: write portable
`sh`, without arrays, `[[ ]]` or `$'…'`). With `/usr/bin/jq` for JSON and
`/usr/bin/awk` for arithmetic on decimals, `sh` covers almost every mod.

Another language is fine when the work needs it (heavy parsing, a system API):

- A compiled program (Swift, C) shipped in the mod: build it as a universal binary
  (`arm64` and `x86_64`, since macOS 26 also runs on Intel Macs), ship the binary with its
  executable bit, and ship its sources and a `build.sh` next to it so the user can rebuild it.
- `/usr/bin/osascript -l JavaScript` ships with macOS.
- MUST NOT use `/usr/bin/python3`: on a Mac without the developer tools it is a stub that opens a
  dialog offering to install them, so the command hangs until its timeout. `/usr/bin/perl` and
  `/usr/bin/ruby` ship with macOS 26 but SHOULD NOT be used for new mods: Apple has deprecated
  these runtimes. Node, Homebrew packages and GNU tools are not on a user's Mac.

### A complete script

Every script SHOULD look like this: strict mode, the two helpers, validation of every input, one
place that prints the whole patch.

```sh disk-free/scripts/read.sh
#!/bin/sh
# Reports the free space of the startup volume. Runs as lifecycle.refresh and as the stepper's command.
set -eu

# say ENGLISH RUSSIAN: the text in the user's language, which Toolsy passes as TOOLSY_LOCALE.
say() {
    locale=${TOOLSY_LOCALE-}
    case ${locale%%-*} in
    ru) printf '%s' "$2" ;;
    *) printf '%s' "$1" ;;
    esac
}

# fail MESSAGE: Toolsy shows the last line of standard error as the mod's error.
fail() {
    printf '%s\n' "$*" >&2
    exit 1
}

# Settings arrive as text; a value from an older version, or a missing one, must not break the command.
warn=${TOOLSY_STATE_warnBelow-20}
case $warn in
'' | *[!0-9]* | ?????*) fail "$(say "Warn below: expected a whole number, got" "Предупреждать при: ожидается целое число, получено") «${warn}»" ;;
esac

# "/dev/disk3s1s1  971350180  ...  ...  ..." in 1024-byte blocks; the 4th column is what is available.
free=$(/bin/df -k / | /usr/bin/awk 'NR == 2 { print $4 * 1024 }')
[ -n "$free" ] || fail "$(say "df did not report the startup volume" "df не сообщил о загрузочном томе")"

if [ "$free" -lt $((warn * 1000000000)) ]; then
    level=warn status=$(say "Space is running out" "Место заканчивается")
else
    level=ok status=$(say "Enough space" "Места достаточно")
fi

/usr/bin/jq -n -c --argjson free "$free" --arg status "$status" --arg level "$level" \
    '{free: $free, status: $status, level: $level}'
```

### Reading inputs

```sh
# Settings and live values: TOOLSY_STATE_<key>, text. With `set -u`, read them with ${…-default}.
days=${TOOLSY_STATE_days-7}
case $days in
'' | *[!0-9]*) days=7 ;;            # or fail with a message, as above
esac

# Booleans arrive as true or false.
case ${TOOLSY_STATE_display-false} in
true) flags=-di ;;
*) flags=-i ;;
esac

# A fixed set of words: accept exactly those.
case ${TOOLSY_STATE_mode-} in
fast | normal | quiet) mode=$TOOLSY_STATE_mode ;;
*) mode=normal ;;
esac

# The control's value: absent for a button without "value"; the row's id for a list click.
value=${TOOLSY_VALUE-}

# A path the user typed: expand "~", refuse anything that is not an existing folder.
folder=${TOOLSY_STATE_folder-}
case $folder in
"~") folder=$HOME ;;
"~/"*) folder=$HOME/${folder#"~/"} ;;
esac
[ -d "$folder" ] || { printf 'No such folder: %s\n' "$folder" >&2; exit 1; }
```

Arrays and objects are not in the environment. Set `"stdin": true` on the command and read the
input document:

```sh
input=$(cat)
rows=$(printf '%s' "$input" | /usr/bin/jq -c '.state.rows // []')
first=$(printf '%s' "$input" | /usr/bin/jq -r '.state.rows[0].title // empty')
# Without jq, plutil reads JSON too; it exits with 1 when the path does not exist.
title=$(printf '%s' "$input" | /usr/bin/plutil -extract state.rows.0.title raw -o - - 2>/dev/null || true)
```

Write `${name}`, with braces, when a letter, a digit, `_` or any non-ASCII character follows a
variable (`«${value}»`, `${count}шт`): `/bin/sh` is bash 3.2, which reads the first byte of a
non-ASCII character as part of the name and fails with `unbound variable`.

Always quote expansions: `"$folder"`, never `$folder` (a space splits it into two arguments, a `*`
expands to file names). MUST NOT use `eval`, `sh -c "$text"`, backticks or `$(…)` around input, or
`xargs` without `-0`. Pass input to programs as separate arguments (`--arg name "$value"`, `--`
before a path that may start with `-`).

### Emitting JSON

The safe way is `/usr/bin/jq -n -c`, building the object from named arguments: `--arg` for text
(any character is escaped), `--argjson` for a number, a boolean or `null` that you have validated.

```sh
/usr/bin/jq -n -c --arg status "$status" --arg level "$level" --argjson count "$count" \
    '{status: $status, level: $level, count: $count}'

# A key that may be unknown: null removes it from the state, so nothing stale stays on the page.
/usr/bin/jq -n -c --arg ip "$ip" '{ip: (if $ip == "" then null else $ip end)}'

# List rows from lines of text ("title<TAB>subtitle").
printf '%s\n' "$lines" | /usr/bin/jq -R -s -c \
    'split("\n") | map(select(. != "") | split("\t") | {title: .[0], subtitle: .[1]}) | {rows: .}'

# A notification together with the state.
/usr/bin/jq -n -c --arg status "$status" --arg body "$message" '{status: $status, notify: {body: $body}}'
```

Without `jq`, use the `json_string` function the templates of `toolsy-mod new` ship (see
[Worked examples](#worked-examples)); it prints its argument as a JSON string, escaping quotes and
backslashes and dropping control characters:

```sh
json_string() {
  printf '"%s"' "$(printf '%s' "$1" | tr -d '\000-\037' | sed 's/\\/\\\\/g; s/"/\\"/g')"
}
printf '{"status": %s, "count": %d}\n' "$(json_string "$status")" "$count"
```

Only numbers you have validated go into `%d` or `%s` unquoted. Text that may not be valid UTF-8
(file contents, names from other systems) goes through `/usr/bin/iconv -c -f UTF-8 -t UTF-8` first:
invalid UTF-8 makes the whole patch invalid.

### Reporting status, level and error

- Every patch of `refresh`, of the service and of the switch's commands SHOULD include `status` and
  `level`, so the line under the mod's name always says what is going on.
- When a command cannot do its job, it writes one clear sentence (localised) to standard error and
  exits with 1: Toolsy shows that sentence and keeps the previous state. MUST NOT print a patch and
  exit 0 to report a failure of the command itself.
- When the command did its job and found a problem in the world (offline, disk full), report it in
  the patch: `"level": "warn"` and a `status` that says so, or `"error": "…"` for something the user
  must act on, and `"error": null` once it is resolved.
- Exit statuses other than 0 and 1 mean nothing special to Toolsy; any non-zero status is a failure.

### Localising what scripts report

Use `say ENGLISH RUSSIAN` (above) for every text a command reports: `status`, list rows, error
messages, notifications. Add a branch for every language the manifest translates, so that the page
and what the commands report are in one language. `TOOLSY_LOCALE` may have a region (`ru-us`) and is
absent only when a command is run without it: compare `${TOOLSY_LOCALE%%-*}`. Numbers and dates the
template filters show are localised by Toolsy; a duration is not (`duration` prints `1h 05m` in
every language), so format it in the script when it must read naturally.

### A service

```sh
#!/bin/sh
# lifecycle.service: one patch per line while the mod is on.
set -eu

interval=${TOOLSY_STATE_interval-5}
case $interval in
'' | *[!0-9]* | 0) interval=5 ;;
esac

# Toolsy stops the service with SIGTERM to its whole process group: the shell and the sleep both end,
# so no trap is needed. Set one only to clean up, and exit from it.
trap 'rm -f "$TOOLSY_DATA_DIR/service.tmp"; exit 0' TERM

while :; do
    load=$(/usr/sbin/sysctl -n vm.loadavg | /usr/bin/awk '{ print $2 }')
    /usr/bin/jq -n -c --argjson load "$load" --arg status "Load $load" '{load: $load, status: $status, level: "ok"}'
    sleep "$interval"
done
```

- It reads its settings once: Toolsy restarts it when a setting changes.
- It never exits while there is work: status 0 switches the mod off, any other status is a crash.
  Exit 0 deliberately only when the job is done (a timer that ended, a hold that expired).
- Each patch MUST be on one line and MUST reach Toolsy when it is printed. `jq -n -c` and `printf`
  in the loop do that. A filter in a pipeline holds its output back in a buffer until it is full:
  call `fflush()` after each `print` in `awk`, use `sed -l` and `grep --line-buffered`.
- A service that only holds something (`caffeinate`) `exec`s it, so the stop signal reaches it
  directly; it may print nothing at all.
- It starts at login with the mod on, with the panel closed and before the user does anything:
  it MUST NOT depend on live state that only `refresh` reports.

### Timers that survive sleep

`sleep 600` and `caffeinate -t 600` may not count the time the Mac spends asleep, and Toolsy may
quit in the middle. So:

- Keep the moment something ends as a **setting** in Unix seconds (`"endsAt": 0`): it survives
  restarts, and every command computes `left=$((endsAt - $(date +%s)))` from the wall clock. Never
  count ticks.
- The service sleeps until the end (`sleep $((endsAt - now))`), then reports and notifies. When
  Toolsy starts with the mod on, the restarted service sleeps only for the time left; an end that
  has passed is reported at once.
- Answer `wake` with the command that settles what ended during sleep, and use `refresh` with
  `every: 1` only for a countdown the user watches.
- Settle transitions deterministically (a break starts exactly when its work phase ended, not when
  the command happened to notice): the service and a command may both see the same transition, and
  must report the same patch.

### Idempotent enable, disable and uninstall

- `enable` checks its inputs and fails with a message before changing anything.
- `disable` and `uninstall` MUST succeed when there is nothing to undo (the folder is gone, the
  setting is already off): otherwise the user can never switch the mod off or remove it.
- A lasting effect is reported by `refresh` with `"enabled": true|false`, so the switch follows a
  change made outside Toolsy and the state after a restart.
- Undo exactly what `enable` did, not more: restore the value that was there before (keep it in
  `$TOOLSY_DATA_DIR` or a setting) rather than a value you assume.

### Tools, files and the user

- Programs: only what macOS 26 ships in `/bin`, `/usr/bin`, `/usr/sbin`, `/sbin`, for example
  `awk`, `sed`, `grep`, `date`, `stat`, `df`, `du`, `find`, `sort`, `head`, `tail`, `tr`, `cut`, `wc`,
  `od`, `iconv`, `jq`, `plutil`, `defaults`, `sysctl`, `vm_stat`, `pmset`, `ioreg`, `scutil`,
  `ifconfig`, `ipconfig`, `networksetup`, `route`, `netstat`, `ps`, `lsof`, `pgrep`, `caffeinate`,
  `pbcopy`, `pbpaste`, `mdfind`, `diskutil`, `system_profiler`, `sw_vers`, `chflags`, `tmutil`,
  `osascript`. They are the BSD versions: `sed -i ''`, `date -r <seconds>`, `stat -f`. There is no
  `timeout`, `gdate` or `realpath -m`.
- Paths: `PATH` starts with `/opt/homebrew/bin:/usr/local/bin`, so a bare name may run another
  version the user installed. SHOULD call tools by absolute path; MUST for privileged commands
  (whose `PATH` has the system folders only) and for `jq`.
- Files: write only inside `"$TOOLSY_DATA_DIR"` (kept across updates, deleted on removal). Temporary
  files go there too, or into `mktemp -d` under `"$TMPDIR"`, removed when done. MUST NOT write into
  `$TOOLSY_MOD_DIR`, the user's documents or system locations unless that is the mod's purpose and
  the user asked for it.
- Never wait for a person: no `read`, no `sudo`, no `osascript` dialogs, no program that asks a
  question. Reading the user's protected folders (Desktop, Documents, Downloads, iCloud Drive) or
  data (Contacts, Calendars, Photos, Mail) may make macOS ask the user whether Toolsy may; do it only
  when that is the mod's purpose, and say so in the README.
- No network access unless the user asked for it; never send the user's data anywhere; never
  download and run code.

### Cost

Every run starts a process for the shell and one for each tool it calls. A `refresh` with
`every: 1` whose script calls five tools starts six processes a second while the panel is open;
with `"background": true` it does so all day. So:

- Choose the longest `every` that keeps the page useful: 1 only for a visible countdown or a
  reading that changes every second, 10–60 for most status values, none for values that change only
  when the user acts. Prefer `events` to polling, and a `service` to a fast background refresh.
- Keep slow tools (`system_profiler`, `du` over large folders, `log show`, `find /`, `mdfind`) out of
  frequent schedules, and give their command a `timeout` that fits.
- A command slower than its `every` delays every other command of the mod (they never overlap): the
  user's button waits behind it.
- In a service, do the work of one tick in as few processes as possible, and sleep between ticks.

## Worked examples

Five complete mods, each with every file it runs (the `README.md` that `toolsy-mod new` also writes
is left out). The first four are exactly what `toolsy-mod new <id> --template <name>` writes; the
fifth is Keep Awake, a mod that ships with Toolsy. All of them validate without warnings and are
tested. Copy their patterns; change ids, names and text.

| Example | Shape | Shows |
| --- | --- | --- |
| [uptime](#uptime-a-passive-page) | passive page | `refresh` with `every`, a stepper setting with a `command`, a button, filters `duration`, `date`, `time`, a localised status |
| [hide-folder](#hide-folder-a-switch-with-a-lasting-effect) | switch | `enable`/`disable`/`uninstall` with one script, `refresh` reporting `enabled`, an input `disabled` while on, idempotent undo |
| [load-chart](#load-chart-a-service) | service | a service printing one patch per tick, a chart, a slider setting that restarts the service, a `when` on `enabled` |
| [battery-tile](#battery-tile-a-widget) | widget | a widget with a gauge and `detail`, events `launch`, `wake`, `power`, a notification, `null` for unknown values |
| [keep-awake](#keep-awake-a-switch-service-and-widget) | switch + service + widget | a service that `exec`s `caffeinate` and exits 0 when done, an end time kept as a setting, buttons that set `enabled`, `jq` patches, input validation |

### uptime: a passive page

`toolsy-mod new uptime`. No switch: `check` runs when the panel opens, every 60 seconds while it is
open, after the stepper changes and when the button is clicked.

```json uptime/mod.json
{
  "schema": 1,
  "id": "uptime",
  "name": "Uptime",
  "version": "1.0.0",
  "summary": "Shows how long the Mac has been running",
  "icon": "clock",
  "settings": { "days": 7 },
  "commands": {
    "check": { "exec": "check.sh", "timeout": 10 }
  },
  "lifecycle": {
    "refresh": { "command": "check", "every": 60 }
  },
  "ui": [
    { "type": "value", "label": "Running for", "icon": "clock", "value": "{{uptime|duration|default:…}}", "tint": "{{level}}" },
    { "type": "value", "label": "Started", "icon": "power", "value": "{{bootedAt|date|default:…}} {{bootedAt|time}}" },
    {
      "type": "stepper", "label": "Suggest a restart after", "icon": "bell", "bind": "days",
      "min": 1, "max": 90, "unit": " days", "command": "check",
      "help": "The status turns yellow when the Mac has been running longer than this"
    },
    { "type": "button", "label": "Check now", "icon": "arrow.clockwise", "command": "check" }
  ],
  "localizations": {
    "ru": {
      "Shows how long the Mac has been running": "Показывает, сколько Mac работает без перезагрузки",
      "Running for": "Работает",
      "Started": "Включён",
      "Suggest a restart after": "Советовать перезагрузку через",
      " days": " дн.",
      "The status turns yellow when the Mac has been running longer than this": "Статус станет жёлтым, когда Mac проработает дольше",
      "Check now": "Проверить"
    }
  }
}
```

```sh uptime/check.sh
#!/bin/sh
set -eu

# Prints its argument as a JSON string. Text in a patch must be escaped: a quote or a backslash in
# it would break the JSON, and Toolsy ignores output that is not a JSON object.
json_string() {
  printf '"%s"' "$(printf '%s' "$1" | tr -d '\000-\037' | sed 's/\\/\\\\/g; s/"/\\"/g')"
}

# Prints the first argument, or the second when the user's language is Russian. Commands translate
# what they report themselves; TOOLSY_LOCALE is a code such as "ru" or "en-us", or absent.
text() {
  case ${TOOLSY_LOCALE:-en} in
    ru | ru-*) printf '%s' "$2" ;;
    *) printf '%s' "$1" ;;
  esac
}

# Reports how long the Mac has been running. Toolsy runs it every 60 seconds while the panel is open
# (lifecycle.refresh), after every other command, when "Check now" is clicked and when the stepper
# changes (their "command").
#
# Contract: print one JSON object, a patch merged into the mod's state, and exit 0. On a non-zero
# exit Toolsy keeps the state as it was and shows the last line of standard error as the error.

# "{ sec = 1731700000, usec = 0 } Sat Nov 16 09:00:00 2024" -> 1731700000
booted=$(sysctl -n kern.boottime | sed -n 's/^{ sec = \([0-9]*\),.*/\1/p')
if [ -z "$booted" ]; then
  echo "Cannot read the boot time from sysctl" >&2
  exit 1
fi
uptime=$(( $(date +%s) - booted ))

# Settings arrive as text in TOOLSY_STATE_<key>. Check them before use: the value may come from an
# older version of the mod, or be missing.
days=${TOOLSY_STATE_days:-7}
case $days in
  '' | *[!0-9]*) days=7 ;;
esac

if [ "$uptime" -gt $(( days * 86400 )) ]; then
  level=warn
  status=$(text "Time to restart" "Пора перезагрузить")
else
  level=ok
  status=$(text "Fine" "В порядке")
fi

# "status" and "level" are read by Toolsy itself: the line under the mod's name and its colour.
printf '{"uptime": %d, "bootedAt": %d, "status": %s, "level": "%s"}\n' \
  "$uptime" "$booted" "$(json_string "$status")" "$level"
```

### hide-folder: a switch with a lasting effect

`toolsy-mod new hide-folder --template switch`. The effect (a file flag) lasts by itself, so
`status` reports `enabled` and the switch follows the truth; `show` succeeds when there is nothing
to undo.

```json hide-folder/mod.json
{
  "schema": 1,
  "id": "hide-folder",
  "name": "Hide folder",
  "version": "1.0.0",
  "summary": "Hides a folder from Finder while it is switched on",
  "icon": "eye.slash",
  "settings": { "folder": "" },
  "commands": {
    "hide": { "exec": "folder.sh", "args": ["hide"], "timeout": 10 },
    "show": { "exec": "folder.sh", "args": ["show"], "timeout": 10 },
    "status": { "exec": "folder.sh", "args": ["status"], "timeout": 10 }
  },
  "lifecycle": {
    "enable": "hide",
    "disable": "show",
    "uninstall": "show",
    "refresh": { "command": "status", "every": 30 }
  },
  "ui": [
    {
      "type": "input", "label": "Folder", "icon": "folder", "bind": "folder", "placeholder": "~/Documents/Private",
      "command": "status", "disabled": "enabled", "help": "Switch the mod off to choose another folder"
    },
    { "type": "text", "text": "Finder hides the folder while the mod is on. Its files stay where they are.", "style": "caption" }
  ],
  "localizations": {
    "ru": {
      "Hides a folder from Finder while it is switched on": "Скрывает папку в Finder, пока мод включён",
      "Folder": "Папка",
      "Switch the mod off to choose another folder": "Чтобы выбрать другую папку, выключите мод",
      "Finder hides the folder while the mod is on. Its files stay where they are.": "Пока мод включён, Finder не показывает папку. Файлы в ней остаются на месте."
    }
  }
}
```

```sh hide-folder/folder.sh
#!/bin/sh
set -eu

# Prints its argument as a JSON string. Text in a patch must be escaped: a quote or a backslash in
# it would break the JSON, and Toolsy ignores output that is not a JSON object.
json_string() {
  printf '"%s"' "$(printf '%s' "$1" | tr -d '\000-\037' | sed 's/\\/\\\\/g; s/"/\\"/g')"
}

# Prints the first argument, or the second when the user's language is Russian. Commands translate
# what they report themselves; TOOLSY_LOCALE is a code such as "ru" or "en-us", or absent.
text() {
  case ${TOOLSY_LOCALE:-en} in
    ru | ru-*) printf '%s' "$2" ;;
    *) printf '%s' "$1" ;;
  esac
}

# Hides a folder from Finder (the "hidden" file flag) while the mod is on.
#   hide    lifecycle.enable. On success Toolsy turns the switch on; on failure it stays off and the
#           last line of standard error is shown as the error.
#   show    lifecycle.disable and lifecycle.uninstall. It must succeed when there is nothing to undo,
#           or the mod could never be switched off or removed.
#   status  lifecycle.refresh, and the folder field's command. "enabled" in its patch moves the switch
#           to the truth, so it follows the folder after a restart or a change made in Terminal.

# The setting as typed; "~/" stands for the home folder.
folder=${TOOLSY_STATE_folder:-}
case $folder in
  "~") folder=$HOME ;;
  "~/"*) folder=$HOME/${folder#"~/"} ;;
esac
folder=${folder%/}

# The patch every action ends with. The status names the folder, which may hold any character:
# json_string keeps the JSON valid.
report() { # report true|false <status>
  if [ "$1" = true ]; then level=ok; else level=off; fi
  printf '{"enabled": %s, "status": %s, "level": "%s"}\n' "$1" "$(json_string "$2")" "$level"
}

is_hidden() {
  stat -f '%Sf' "$folder" | grep -qw hidden
}

case ${1:-} in
  hide)
    if [ -z "$folder" ]; then
      printf '%s\n' "$(text "Choose a folder first" "Сначала выберите папку")" >&2
      exit 1
    fi
    if [ ! -d "$folder" ]; then
      printf '%s: %s\n' "$(text "No such folder" "Нет такой папки")" "$folder" >&2
      exit 1
    fi
    chflags hidden "$folder"
    report true "$(text "Hidden" "Скрыта"): ${folder##*/}"
    ;;
  show)
    if [ -n "$folder" ] && [ -d "$folder" ]; then
      chflags nohidden "$folder"
    fi
    report false "$(text "Visible" "Видна")"
    ;;
  status)
    if [ -z "$folder" ]; then
      report false "$(text "No folder chosen" "Папка не выбрана")"
    elif [ -d "$folder" ] && is_hidden; then
      report true "$(text "Hidden" "Скрыта"): ${folder##*/}"
    else
      report false "$(text "Visible" "Видна")"
    fi
    ;;
  *)
    echo "usage: folder.sh hide|show|status" >&2
    exit 2
    ;;
esac
```

### load-chart: a service

`toolsy-mod new load-chart --template service`. The service starts when the mod is switched on and
prints a patch every few seconds; changing the slider restarts it with the new interval.

```json load-chart/mod.json
{
  "schema": 1,
  "id": "load-chart",
  "name": "Load chart",
  "version": "1.0.0",
  "summary": "Charts the Mac's load while it is switched on",
  "icon": "waveform.path.ecg",
  "settings": { "interval": 2 },
  "commands": {
    "watch": { "exec": "watch.sh" }
  },
  "lifecycle": { "service": "watch" },
  "ui": [
    { "type": "chart", "label": "Load average", "series": [ { "bind": "load", "label": "1 minute" } ], "style": "area", "points": 60, "min": 0 },
    { "type": "value", "label": "Now", "icon": "cpu", "value": "{{load|fixed:2|default:—}} / {{cores|default:—}} cores", "tint": "{{level}}" },
    { "type": "slider", "label": "Measure every", "icon": "timer", "bind": "interval", "min": 1, "max": 10, "step": 1, "unit": " s" },
    { "type": "text", "text": "Switch the mod on to start measuring.", "style": "caption", "when": "!enabled" }
  ],
  "localizations": {
    "ru": {
      "Charts the Mac's load while it is switched on": "Строит график нагрузки Mac, пока мод включён",
      "Load average": "Средняя нагрузка",
      "1 minute": "1 минута",
      "Now": "Сейчас",
      "{{load|fixed:2|default:—}} / {{cores|default:—}} cores": "{{load|fixed:2|default:—}} / ядер: {{cores|default:—}}",
      "Measure every": "Измерять каждые",
      " s": " с",
      "Switch the mod on to start measuring.": "Включите мод, чтобы начать измерения."
    }
  }
}
```

```sh load-chart/watch.sh
#!/bin/sh
set -eu

# Prints its argument as a JSON string. Text in a patch must be escaped: a quote or a backslash in
# it would break the JSON, and Toolsy ignores output that is not a JSON object.
json_string() {
  printf '"%s"' "$(printf '%s' "$1" | tr -d '\000-\037' | sed 's/\\/\\\\/g; s/"/\\"/g')"
}

# Prints the first argument, or the second when the user's language is Russian. Commands translate
# what they report themselves; TOOLSY_LOCALE is a code such as "ru" or "en-us", or absent.
text() {
  case ${TOOLSY_LOCALE:-en} in
    ru | ru-*) printf '%s' "$2" ;;
    *) printf '%s' "$1" ;;
  esac
}

# The mod's service (lifecycle.service). Toolsy starts it when the mod is switched on and stops it
# with SIGTERM to everything it started when the mod is switched off or Toolsy quits.
#
# Contract: every line printed is a patch, applied at once; the chart records "load" from each one.
# Never exit on your own: exit status 0 switches the mod off, any other status restarts the service
# after a delay and shows the last line of standard error as the error. Toolsy restarts the service
# when a setting changes, so reading settings once, at the start, is enough.

# The slider stores whole seconds (its step is 1); anything else falls back to the default.
interval=${TOOLSY_STATE_interval:-2}
case $interval in
  '' | *[!0-9]* | 0) interval=2 ;;
esac
cores=$(sysctl -n hw.ncpu)

while :; do
  # "{ 1.52 1.61 1.70 }" -> the average over the last minute
  load=$(sysctl -n vm.loadavg | awk '{ print $2 }')
  # More load than cores means work is waiting for a processor.
  if awk -v load="$load" -v cores="$cores" 'BEGIN { exit !(load > cores) }'; then
    level=warn
    status=$(text "Busy" "Высокая нагрузка")
  else
    level=ok
    status=$(text "Normal" "Нагрузка в норме")
  fi
  printf '{"load": %s, "cores": %s, "status": %s, "level": "%s"}\n' "$load" "$cores" "$(json_string "$status")" "$level"
  sleep "$interval"
done
```

### battery-tile: a widget

`toolsy-mod new battery-tile --template widget`. No switch and no page controls: the dashboard
tile is the interface. `read` keeps it current; `changed` answers the `power` event and notifies.

```json battery-tile/mod.json
{
  "schema": 1,
  "id": "battery-tile",
  "name": "Battery tile",
  "version": "1.0.0",
  "summary": "Shows the battery on the dashboard and tells when the power source changes",
  "icon": "battery.75percent",
  "settings": { "announce": true },
  "commands": {
    "read": { "exec": "battery.sh", "args": ["read"], "timeout": 10 },
    "changed": { "exec": "battery.sh", "args": ["changed"], "timeout": 10 }
  },
  "lifecycle": {
    "refresh": { "command": "read", "every": 60 },
    "events": { "launch": "read", "wake": "read", "power": "changed" }
  },
  "widgets": [
    {
      "id": "battery",
      "title": "Battery",
      "value": "{{percent|percent|default:—}}",
      "tint": "{{level}}",
      "gauge": { "bind": "percent", "min": 0, "max": 100 },
      "detail": [
        {
          "type": "row", "children": [
            { "type": "stat", "label": "Power source", "value": "{{source|default:—}}" },
            { "type": "stat", "label": "Time left", "value": "{{remaining|default:—}}" }
          ]
        },
        { "type": "toggle", "label": "Notify when the power source changes", "icon": "bell", "bind": "announce" }
      ]
    }
  ],
  "localizations": {
    "ru": {
      "Shows the battery on the dashboard and tells when the power source changes": "Показывает аккумулятор на панели и сообщает, когда меняется источник питания",
      "Battery": "Аккумулятор",
      "Power source": "Питание",
      "Time left": "Осталось",
      "Notify when the power source changes": "Сообщать о смене источника питания"
    }
  }
}
```

```sh battery-tile/battery.sh
#!/bin/sh
set -eu

# Prints its argument as a JSON string. Text in a patch must be escaped: a quote or a backslash in
# it would break the JSON, and Toolsy ignores output that is not a JSON object.
json_string() {
  printf '"%s"' "$(printf '%s' "$1" | tr -d '\000-\037' | sed 's/\\/\\\\/g; s/"/\\"/g')"
}

# Prints the first argument, or the second when the user's language is Russian. Commands translate
# what they report themselves; TOOLSY_LOCALE is a code such as "ru" or "en-us", or absent.
text() {
  case ${TOOLSY_LOCALE:-en} in
    ru | ru-*) printf '%s' "$2" ;;
    *) printf '%s' "$1" ;;
  esac
}

# Reads the battery for the widget. The mod has no switch, so Toolsy runs these whenever their moment
# comes:
#   read     lifecycle.refresh (every 60 s while the panel is open) and the launch and wake events.
#   changed  the power event: the Mac switched between the adapter and the battery. Reads, then
#            announces the new source with "notify" unless the user switched that off.

# Now drawing from 'Battery Power'
#  -InternalBattery-0 (id=4653155) 82%; discharging; 3:41 remaining present: true
battery=$(pmset -g batt)
case $battery in
  *"'AC Power'"*) source=$(text "Power adapter" "Сеть") ;;
  *) source=$(text "Battery" "Аккумулятор") ;;
esac
line=$(printf '%s\n' "$battery" | grep InternalBattery || true)
percent=$(printf '%s\n' "$line" | sed -n 's/.*[[:space:]]\([0-9][0-9]*\)%;.*/\1/p')
remaining=$(printf '%s\n' "$line" | sed -n 's/.*; \([0-9][0-9]*:[0-9][0-9]\) remaining.*/\1/p')

# null removes a key, so a value an earlier run reported does not linger.
if [ -z "$percent" ]; then
  percent=null
  status=$(text "No battery" "Нет аккумулятора")
  level=off
else
  case $line in
    *"; charging;"* | *"; finishing charge;"*) status=$(text "Charging" "Заряжается") ;;
    *"; discharging;"*) status=$(text "On battery" "От аккумулятора") ;;
    *"; charged;"*) status=$(text "Charged" "Заряжен") ;;
    *) status=$(text "Not charging" "Не заряжается") ;;
  esac
  if [ "$percent" -le 20 ]; then level=warn; else level=ok; fi
fi
case $remaining in
  '' | 0:00) remaining=null ;;
  *) remaining=$(json_string "$remaining") ;;
esac

# "notify" shows a system notification; it is never stored in the state.
notify=
if [ "${1:-}" = changed ] && [ "${TOOLSY_STATE_announce:-true}" = true ]; then
  notify=", \"notify\": $(json_string "$(text "Power source" "Питание"): $source")"
fi

printf '{"percent": %s, "remaining": %s, "source": %s, "status": %s, "level": "%s"%s}\n' \
  "$percent" "$remaining" "$(json_string "$source")" "$(json_string "$status")" "$level" "$notify"
```

### keep-awake: a switch, service and widget

Keep Awake ships with Toolsy. Its service is `caffeinate`, which exits with status 0 when its time
is up and so switches the mod off; the end of the hold is a setting, so it survives a restart of
Toolsy; the tile's buttons switch the mod by setting `enabled` in their patches; every patch is
built with `jq`.

```json keep-awake/mod.json
{
  "schema": 1,
  "id": "keep-awake",
  "name": "Keep Awake",
  "version": "1.0.0",
  "author": "Toolsy",
  "summary": "Keeps the Mac awake for a while or until you switch it off",
  "icon": "cup.and.saucer.fill",
  "tint": "orange",
  "settings": {
    "duration": 60,
    "display": false,
    "until": 0
  },
  "commands": {
    "start": { "exec": "scripts/keep-awake.sh", "args": ["start"] },
    "stop": { "exec": "scripts/keep-awake.sh", "args": ["stop"] },
    "retime": { "exec": "scripts/keep-awake.sh", "args": ["retime"] },
    "status": { "exec": "scripts/keep-awake.sh", "args": ["status"] },
    "hold": { "exec": "scripts/keep-awake.sh", "args": ["hold"] }
  },
  "lifecycle": {
    "enable": "start",
    "disable": "stop",
    "service": "hold",
    "refresh": { "command": "status", "every": 15 },
    "events": { "wake": "status" }
  },
  "ui": [
    { "type": "text", "text": "The Mac sleeps as usual. Switch Keep Awake on to stop it from going to sleep on its own.", "style": "caption", "when": "!enabled" },
    {
      "type": "row",
      "when": "enabled",
      "children": [
        { "type": "stat", "label": "Ends", "icon": "clock", "value": "{{until|time}}", "when": "until > 0" },
        { "type": "stat", "label": "Ends", "icon": "infinity", "value": "When switched off", "when": "until == 0" },
        { "type": "stat", "label": "Display", "icon": "display", "value": "{{display|either:Stays on:Sleeps as usual}}" }
      ]
    },
    {
      "type": "section",
      "title": "Settings",
      "footer": "A new duration chosen while Keep Awake is on counts from that moment. Closing the lid or choosing Sleep still puts the Mac to sleep.",
      "children": [
        {
          "type": "picker", "label": "Keep awake for", "icon": "timer", "bind": "duration", "command": "retime",
          "options": [
            { "value": 30, "label": "30 min" },
            { "value": 60, "label": "1 hour" },
            { "value": 120, "label": "2 hours" },
            { "value": 0, "label": "Indefinitely" }
          ]
        },
        { "type": "toggle", "label": "Keep the display on", "icon": "display", "bind": "display", "help": "Without this the display may dim and sleep while the Mac stays awake." }
      ]
    }
  ],
  "widgets": [
    {
      "id": "status",
      "value": "{{status|default:—}}",
      "tint": "{{enabled|either:orange:off}}",
      "detail": [
        {
          "type": "row",
          "children": [
            { "type": "button", "label": "Turn On", "icon": "power", "command": "start", "style": "prominent", "when": "!enabled" },
            { "type": "button", "label": "Turn Off", "icon": "power", "command": "stop", "when": "enabled" }
          ]
        },
        { "type": "stat", "label": "Ends", "icon": "clock", "value": "{{until|time}}", "when": "enabled && until > 0" },
        {
          "type": "picker", "label": "Keep awake for", "bind": "duration", "command": "retime", "style": "menu",
          "options": [
            { "value": 30, "label": "30 min" },
            { "value": 60, "label": "1 hour" },
            { "value": 120, "label": "2 hours" },
            { "value": 0, "label": "Indefinitely" }
          ]
        },
        { "type": "toggle", "label": "Keep the display on", "bind": "display" }
      ]
    }
  ],
  "localizations": {
    "ru": {
      "Keep Awake": "Не засыпать",
      "Keeps the Mac awake for a while or until you switch it off": "Не даёт Mac уснуть на время или пока вы не выключите мод",
      "The Mac sleeps as usual. Switch Keep Awake on to stop it from going to sleep on its own.": "Mac засыпает как обычно. Включите мод, чтобы он не уснул сам.",
      "Ends": "Окончание",
      "When switched off": "При выключении",
      "Display": "Дисплей",
      "{{display|either:Stays on:Sleeps as usual}}": "{{display|either:Не гаснет:Гаснет как обычно}}",
      "Settings": "Настройки",
      "A new duration chosen while Keep Awake is on counts from that moment. Closing the lid or choosing Sleep still puts the Mac to sleep.": "Новая длительность, выбранная во время работы, отсчитывается с этого момента. Если закрыть крышку или выбрать «Режим сна», Mac всё равно уснёт.",
      "Keep awake for": "Длительность",
      "30 min": "30 мин",
      "1 hour": "1 час",
      "2 hours": "2 часа",
      "Indefinitely": "Бессрочно",
      "Keep the display on": "Не выключать дисплей",
      "Without this the display may dim and sleep while the Mac stays awake.": "Без этого дисплей может погаснуть, хотя Mac не уснёт.",
      "Turn On": "Включить",
      "Turn Off": "Выключить"
    }
  }
}
```

```sh keep-awake/scripts/keep-awake.sh
#!/bin/sh
# Keep Awake's commands; $1 names one. The service holds a caffeinate assertion; everything else
# keeps `until`, the moment the hold ends, which is a setting so that it survives a restart of Toolsy.
set -eu

# Patches are built with jq (`jq -n --arg …`), which escapes whatever text it is given, so nothing a
# command reports can break the JSON.

# say ENGLISH RUSSIAN: prints the text in the user's language, which Toolsy passes as TOOLSY_LOCALE.
say() {
    locale=${TOOLSY_LOCALE-}
    case ${locale%%-*} in
    ru) printf '%s' "$2" ;;
    *) printf '%s' "$1" ;;
    esac
}

fail() {
    printf '%s\n' "$*" >&2
    exit 1
}

# require_whole VALUE MIN MAX NAME: fails unless VALUE is a whole number between MIN and MAX.
require_whole() {
    case $1 in
    '' | *[!0-9]* | ???????????*) fail "$4: $(say "expected a whole number, got" "ожидается целое число, получено") «$1»" ;;
    esac
    [ "$1" -ge "$2" ] && [ "$1" -le "$3" ] ||
        fail "$4: $(say "expected $2 to $3, got" "ожидается от $2 до $3, получено") $1"
}

# minutes_text SECONDS: a time left in whole minutes, rounded up: "5 min", "1 h 05 min".
minutes_text() {
    minutes=$((($1 + 59) / 60))
    if [ "$minutes" -lt 60 ]; then
        say "$minutes min" "$minutes мин"
    else
        hours=$((minutes / 60))
        minutes=$(printf '%02d' $((minutes % 60)))
        say "$hours h $minutes min" "$hours ч $minutes мин"
    fi
}

now=$(date +%s)
# Minutes to stay awake after switching on; 0 means until switched off.
duration=${TOOLSY_STATE_duration-}
# When the hold ends, in Unix seconds; 0 while it is off or has no end.
until=${TOOLSY_STATE_until-}
display=${TOOLSY_STATE_display-}
require_whole "$duration" 0 1440 "$(say "Duration" "Длительность")"
require_whole "$until" 0 9999999999 "$(say "End time" "Время окончания")"
case $display in
true | false) ;;
*) fail "$(say "Keep the display on: expected true or false, got" "Не выключать дисплей: ожидается true или false, получено") «${display}»" ;;
esac

# report ON END: the patch for a hold switched ON (true/false) that ends at END. It sets `enabled`
# itself, so the buttons that run these commands switch the mod like its main switch does.
report() {
    if [ "$1" = false ]; then
        status=$(say "Off" "Выключено") level=off
    elif [ "$2" -eq 0 ]; then
        status=$(say "On" "Включено") level=ok
    else
        status=$(say "$(minutes_text $(($2 - now))) left" "Ещё $(minutes_text $(($2 - now)))") level=ok
    fi
    jq -n -c --argjson enabled "$1" --argjson until "$2" --arg status "$status" --arg level "$level" \
        '{enabled: $enabled, until: $until, status: $status, level: $level}'
}

# The end of a hold started now.
end_from_now() {
    if [ "$duration" -eq 0 ]; then echo 0; else echo $((now + duration * 60)); fi
}

case ${1-} in
start) # The main switch and the Turn On button.
    report true "$(end_from_now)"
    ;;
stop) # The main switch and the Turn Off button.
    report false 0
    ;;
retime) # A new duration chosen while on counts from now; while off it applies at the next start.
    [ "${TOOLSY_STATE_enabled-}" = true ] || exit 0
    report true "$(end_from_now)"
    ;;
status) # Refresh and wake: caffeinate's own timer may not count time the Mac sleeps, so a hold
    # whose end passed during sleep is switched off here.
    if [ "${TOOLSY_STATE_enabled-}" != true ]; then
        report false 0
    elif [ "$until" -ne 0 ] && [ "$now" -ge "$until" ]; then
        report false 0
    else
        report true "$until"
    fi
    ;;
hold) # The service. Toolsy restarts it when a setting changes and when it starts with the mod on.
    command -v caffeinate >/dev/null ||
        fail "$(say "caffeinate is missing from /usr/bin. Reinstall macOS to restore it." "В /usr/bin нет caffeinate. Переустановите macOS, чтобы вернуть его.")"
    # -i keeps the Mac from idle sleep, -d the display from sleeping as well.
    flags=-i
    [ "$display" = false ] || flags=-di
    [ "$until" -ne 0 ] || exec caffeinate "$flags"
    # Exiting with status 0 switches the mod off: the end passed while Toolsy was not running.
    [ "$now" -lt "$until" ] || exit 0
    # caffeinate exits with status 0 when its timeout ends, which switches the mod off.
    exec caffeinate "$flags" -t $((until - now))
    ;;
*)
    fail "$(say "Unknown command" "Неизвестная команда") «${1-}»"
    ;;
esac
```

## Mistakes and their fixes

Each row is a mistake models make with this format, what the tool says about it (verbatim; `X` and
`1` are the example mod's id and version), and the fix. A dash means nothing reports it: only
`preview` or `run` shows the effect.

| Mistake | The tool says | Fix |
| --- | --- | --- |
| A control type that does not exist (`label`, `image`, `textarea`, `link`). | `ui[0].type: unknown control type "label"` | Use a type of the [Interface](#interface) tables: `text` for a label, a `button` with `open` for a link. |
| A field of another control: `title` on a `value`. | `ui[0]: missing required field "label"` | Use the fields of that type's row exactly. |
| An optional field that does not exist on the type: `label` on a `list`, `placeholder` on a `picker`, `color` instead of `tint`. | — (unknown fields are ignored) | Check every field against the type's row; a caption above a list is a `text` with `"style": "caption"`. |
| A template in an expression: `"when": "{{enabled}}"`. | `ui[0].when: unexpected "{"` | `"when": "enabled"`. Expressions name keys directly. |
| `=` instead of `==`. | `ui[0].when: unexpected "="` | `mode == 'x'`. |
| A chained comparison: `1 < a < 3`. | `ui[0].when: only one comparison is allowed without parentheses` | `1 < a && a < 3`. |
| Negating a key: `-a > 1`. | `ui[0].when: unexpected "-" where a value is expected` | `0 - a > 1`. |
| An event command in a mod with a switch that is meant to act while the mod is off (a reminder that something is off). | — (event commands run only while the mod is on; `refresh` still runs when the panel opens) | Act on events only while on, or make the mod one without a switch. |
| A `when` that reads a key nothing sets (`"when": "connected"` when the script reports `online`). | — (`preview` shows the control `[hidden]` in every state) | Use the exact keys the patches contain; preview with the patch `run` printed. |
| Array index syntax in a template: `{{rows[0].title}}`. | `ui[0].text: "{{rows[0].title}}" does not start with a valid state key or path` | `{{rows.0.title}}`. |
| An argument to a filter that takes none (`bytes:2`), or a filter that does not exist. | `ui[0].text: the filter "bytes" takes no argument` | Use the filters of the [Templates](#templates) table exactly as written there. |
| A placeholder broken by a translation: `"{{n}} files": "{{n} файлов"`. | `localizations.ru: ui[0].text: "{{" is not closed` | Copy the placeholders and filters of the source exactly; translate only the words. |
| A translation whose source differs from the manifest's text by one character. | `warning: localizations.ru: "Onn" is not the text of any translated field, so this entry is never used` | Copy the source text exactly, spaces and placeholders included. |
| Binding a host key to an input: a toggle on `enabled`. | `ui[0]: "enabled" is managed by the host and cannot be bound to an input` | The main switch is `enabled`; for a second place to switch, a button whose command prints `{"enabled": true}`. |
| A setting named like a host key. | `settings: "status" is reserved for the host` | Rename it (`statusText`), or report `status` from a command. |
| Binding `notify`. | `ui[1]: bind "notify" is not state: a patch's notify is shown, never stored` | Report the text in another key too if the page must show it. |
| A privileged service. | `lifecycle.service: a service cannot be privileged` | Make the service unprivileged; give root work to one-shot privileged commands it cannot start itself (the switch's `enable`/`disable`, buttons). |
| A widget without a value. | `widgets[0]: missing required field "value"` | Every widget has a non-blank `value` template with a `default:`. |
| A blank widget value: `"value": " "`. | `widgets[0].value: must not be empty` | Give it a template with a `default:` filter, as in the widget examples. |
| A hook naming a command that does not exist. | `lifecycle.refresh.command: command "read" is not defined` | Define the command under `commands`, with the same name. |
| `every` below one second. | `lifecycle.refresh.every must be at least 1 second` | Use a service for faster readings. |
| `exec` with an absolute path: `"exec": "/bin/date"`. | `commands.r: exec must be a relative path inside the mod` | `"shell": "/bin/date +%s"`, or ship a script and `exec` it. |
| An `exec` file that is missing or not executable. | `commands.r: exec file "r.sh" is not part of the mod` / `commands.root: exec file "scripts/read.sh" is not executable (chmod +x)` | Ship the file at that path; `chmod +x` it before packing. |
| A script without a `#!` line. | `error:   Toolsy shows "Cannot start …/nobang.sh: The operation couldn’t be completed. Exec format error"` (from `run`) | Start every `exec` script with `#!/bin/sh`. |
| A `shell` command starting with a script of the mod that is missing. | `warning: commands.a: shell starts with "scripts/a.sh", which is not a file of the mod` | Use `exec` for files of the mod. |
| Both `exec` and `shell`. | `commands.r: a command needs exactly one of "exec" and "shell"` | Keep one. |
| An event that does not exist (`sleep`, `login`, `battery`). | `lifecycle.events: unknown event "sleep"; expected one of "launch", "wake", "network", "power"` | Only those four exist. |
| `options` and `optionsFrom` together. | `ui[0]: a picker needs exactly one of "options" and "optionsFrom"` | Keep one. |
| A button with two actions. | `ui[0]: a button needs exactly one of "command", "open" and "copy"` | One button per action. |
| A row holding a section. | `ui[0]: a row cannot contain a section or another row` | Rows hold leaf controls; put rows inside sections. |
| A slider without its range. | `ui[0]: missing required field "min"` | Sliders need `min` and `max`. |
| An id with capitals or spaces. | `id "MyMod" is invalid: use 1–64 lowercase letters, digits, ".", "_" or "-", starting and ending with a letter or digit` | `my-mod`. |
| A setting default of the wrong type for its control: `"1"` for a picker whose values are numbers, `"yes"` for a toggle. | `warning: ui[2]: the default of setting "mode", "1", matches the value of none of the options (1, 2); the picker shows nothing selected` | Default to an option's value with its type; toggles default to `true` or `false`. |
| JSON built by string concatenation, with a quote in the text. | `output:  ignored, not JSON (Unexpected character 'h' in object around line 1, column 17.):` (from `run`) | `/usr/bin/jq -n -c --arg title "$name" '{title: $title}'`. |
| Plain text on standard output. | `output:  ignored, not JSON (Unexpected character 'W' around line 1, column 1.):` | Print a patch, write progress to standard error, or set `capture`. |
| An array instead of an object. | `output:  ignored, JSON but not an object: [1,2]` | Wrap it: `{"rows": [1,2]}`. |
| Pretty-printed JSON from a service (`jq` without `-c`). | `line 1: ignored, not JSON (Unexpected end of file): {` | `jq -c`: one object per line. |
| A service that ends at once (`echo …` and nothing else). | `note:    the service ended with exit status 0: Toolsy switches the mod off, as if the user had (running disable)` | Loop, or `exec` a long-running program. A one-shot report is a `refresh`. |
| A service that never prints (output buffered by a pipeline). | `output:  no lines` (from `run … --for 5`) | Flush each line: `fflush()` in awk, `sed -l`, `grep --line-buffered`. |
| A variable followed by a non-ASCII character: `"«$warn»"`. | `error:   Toolsy shows "…/scripts/read.sh: line 23: warn�: unbound variable"` | `"«${warn}»"`: braces around every variable followed by a non-ASCII character. |
| An unquoted variable: `ls -d $TOOLSY_STATE_folder` with a space in the folder. | `error:   Toolsy shows "ls: Files: No such file or directory"` | `ls -d "$TOOLSY_STATE_folder"`. Quote every expansion. |
| A command slower than its timeout or than its `every`. | `result:  FAILED: timed out after 1.06 s, its timeout of 1 s, and was killed` | Make it faster, raise `timeout` to fit the slowest real run, and choose a longer `every`. |
| `notify` without a body. | `note:    notify has no text to show, so no notification appears` | `{"notify": {"title": "…", "body": "…"}}` or a string. |
| A privileged command tried with `run`. | `toolsy-mod: "root" is privileged: Toolsy runs it as root through its helper, and toolsy-mod never does. Add --as-user …` (exit status 2) | Test it with `--as-user`; keep what can run unprivileged unprivileged. |
| A command name that the mod does not have. | `toolsy-mod: w has no command "nope"; its commands: bad, done, quiet, read, root` (exit status 2) | Use the names under `commands`. |
| Previewing a language the mod has no table for. | `toolsy-mod: --language: w has no localization for "de"; it has: ru` (exit status 2) | Add the table, or preview a language it has. |
| `"schema": 2` or a missing `schema`. | `schema 2 is not supported by this version of Toolsy (expected 1)` | `"schema": 1`. |
| A number reported as text (`"42"`) and shown through a numeric filter. | — (`fixed:1` leaves the text `42` as it is, a gauge shows nothing) | Report numbers as JSON numbers: `--argjson n "$n"`. |
| `python3` in a script. | — (on a Mac without developer tools a dialog appears and the command times out) | Use `sh`, `awk`, `jq`. |
| Writing into the mod's folder. | — (works until the mod is privileged, then its privileged commands are refused; developer mode restarts the service for every write) | Write into `$TOOLSY_DATA_DIR`. |

## Final checklist

Tick every item before you answer. Each is a command with its expected result or a property of the
files you can check by reading them.

1. `toolsy-mod validate <folder>` prints `OK <id> <version>` and no line starting with `warning:`.
2. Every command under `commands` has been run with `toolsy-mod run` and its report shows
   `result:  exit status 0` (for the service: `still running after …`), `output:  a patch` (or a
   patch on every `line N:`), and no `note:` that something was ignored. Each command that depends on
   a setting or a control was also run with `--state`, `--key`/`--value` as the control sends them.
3. Every command that can fail was run in its failure case and the report's `error:` line is a
   clear, localised sentence.
4. `toolsy-mod run <folder> <command> --locale ru` shows Russian text in every `status` and message
   (and likewise for every other language the manifest translates).
5. `toolsy-mod preview <folder>` with the starting state, a typical state (the patch `run` printed),
   an empty state and an error state shows no `{{`, no empty label or value, every control
   `[hidden]` exactly when intended, every widget with a value, and every picker with a `[selected]`
   option (a picker with `optionsFrom` once the state holds its options).
6. `toolsy-mod preview <folder> --language ru` shows every text translated.
7. Every field name in `mod.json` appears in this document's tables for that object; every
   template is in a template field; every `when`/`disabled` is an expression without braces.
8. Every key a template, expression, `bind`, gauge, chart or list reads is a setting or appears in a
   patch that `run` printed.
9. No setting, input `bind` or `capture` uses `enabled`, `status`, `level`, `error` or `notify`.
10. Every script starts with `#!/bin/sh` and `set -eu`, is executable (`ls -l` shows `x`), quotes
    every expansion, validates every `TOOLSY_*` value it uses, and builds JSON with `jq` or
    `json_string`, never by pasting text into a JSON string.
11. Scripts call only programs that ship with macOS, `jq` and every program of a privileged command
    by absolute path; nothing writes outside `$TOOLSY_DATA_DIR`; nothing prompts, uses `sudo` or the
    network unless the user asked for it.
12. A service loops (or `exec`s a long-running program), prints one compact object per line, and
    exits 0 only when its job is done; `toolsy-mod run <folder> <service> --for 5` shows its lines.
13. `disable` and `uninstall` succeed when there is nothing to undo (run them twice in a row).
14. `refresh.every` is the longest that keeps the page useful; `"background": true` appears only
    with a reason stated in the README.
15. A privileged mod: each privileged command needs root, validates every input against an
    allow-list, puts no user-typed text into a command line, calls tools by absolute path; the
    service is not privileged; the README lists each privileged command and why.
16. `localizations` has a table for every language asked for (at least `ru`), with an entry for
    every text a user sees, placeholders identical to the source.
17. `README.md` says what the mod does, what it runs and when, and what it never does.
18. `toolsy-mod pack <folder> -o <id>.toolsymod` prints `OK <id> <version> <file>`, and
    `toolsy-mod validate <id>.toolsymod` prints `OK <id> <version>`.
19. Your answer contains every file in full (or the packed file), the installation steps, what the
    mod runs and never does, and what you verified and what you could not.
