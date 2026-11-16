# Toolsy mod format

A mod adds one feature to Toolsy. It is a folder with a `mod.json` manifest and, optionally,
the programs that manifest refers to. Toolsy renders the mod's interface natively from the
manifest and starts the mod's programs only when something has to happen, so a mod that is
switched off costs nothing and a mod that is switched on costs only what it declares.

A mod never runs inside the Toolsy process. Everything it does happens in short-lived child
processes (or one long-lived *service* process), in any language.

- [Packaging](#packaging)
- [Manifest](#manifest)
- [State](#state)
- [Commands](#commands)
- [Lifecycle](#lifecycle)
- [Interface](#interface)
- [Widgets](#widgets)
- [Localization](#localization)
- [Templates and expressions](#templates-and-expressions)
- [Administrator privileges](#administrator-privileges)
- [Examples](#examples)

## Packaging

| Form | What it is |
| --- | --- |
| `name.toolsymod` | A zip archive with `mod.json` at its root (or inside a single top-level folder). This is the file users install. |
| a folder | An unpacked mod: `mod.json` plus files. Handy while developing. |
| a lone `.json` file | A manifest on its own, for mods that only use `shell` commands. |

Install a mod by dropping it on the Toolsy menu bar icon or panel, with the **+** button, or by
double-clicking a `.toolsymod` file. Remove it from its page in the panel.

Rules for the contents: regular files and folders only (no symbolic links), at most 2 000 files
and 64 MB, paths must be relative and must not differ only by letter case. Executable bits are
preserved. Installing a mod with an `id` that is already installed replaces it and keeps its
settings.

Check and pack a mod with `toolsy-mod`, which ships inside the app
(`Toolsy.app/Contents/Helpers/toolsy-mod`):

```sh
toolsy-mod validate path/to/mod        # checks mod.json and every file it refers to
toolsy-mod pack path/to/mod -o name.toolsymod
```

Installed mods live in `~/Library/Application Support/Toolsy/Mods/<id>/`.

## Manifest

```json
{
  "schema": 1,
  "id": "keep-awake",
  "name": "Keep Awake",
  "version": "1.0.0",
  "author": "You",
  "summary": "Stops the Mac from sleeping",
  "icon": "cup.and.saucer.fill",
  "tint": "orange",
  "homepage": "https://example.com/keep-awake",
  "settings": { "displayToo": true },
  "commands": { "hold": { "shell": "[ \"$TOOLSY_STATE_displayToo\" = true ] && display=-d; exec caffeinate -i $display" } },
  "lifecycle": { "service": "hold" },
  "ui": [ { "type": "toggle", "label": "Keep the display on", "bind": "displayToo" } ]
}
```

| Field | Required | Meaning |
| --- | --- | --- |
| `schema` | yes | Format version. Always `1`. |
| `id` | yes | Unique identifier: 1–64 of `a-z 0-9 . _ -`, starting and ending with a letter or digit. |
| `name` | yes | Display name, up to 80 characters. |
| `version` | yes | Free-form version string, up to 32 characters. |
| `author`, `summary`, `homepage` | no | Shown on the mod's page. `homepage` must be `http(s)`. |
| `icon` | no | [SF Symbol](https://developer.apple.com/sf-symbols/) name. |
| `tint` | no | Accent colour, see [Colours](#colours). |
| `settings` | no | Persisted values and their defaults, see [State](#state). |
| `commands` | no | Named programs, see [Commands](#commands). |
| `lifecycle` | no | Which commands Toolsy runs on its own, see [Lifecycle](#lifecycle). |
| `ui` | no | The mod's page, see [Interface](#interface). |
| `widgets` | no | Tiles for the dashboard, see [Widgets](#widgets). |
| `localizations` | no | Translations of the mod's text, see [Localization](#localization). |

Unknown fields are ignored. A manifest that breaks any rule in this document is rejected at
install time with a message that names the offending field.

## State

Every mod has one flat JSON object of state. Keys are identifiers (`[A-Za-z_][A-Za-z0-9_]*`,
up to 64 characters).

- **Settings** are the keys declared under `settings`. Their values survive restarts and are
  what bound controls usually edit. The manifest gives the defaults.
- **Live state** is every other key. Commands report it; it is forgotten when Toolsy quits.

These keys are read by Toolsy itself and cannot be used as settings:

| Key | Type | Effect |
| --- | --- | --- |
| `enabled` | boolean | Position of the mod's main switch. Toolsy sets it after `enable`/`disable`; a command may correct it in its patch, and Toolsy then starts or stops the service to match without running the hooks. It is remembered across restarts. |
| `status` | string | Short line under the mod's name, e.g. `"Active"`. |
| `level` | `"ok"`, `"warn"`, `"error"`, `"off"` | Colour of the status. |
| `error` | string | Failure message shown on the mod. Set by Toolsy when a command fails; a command may also set it in its patch. See [Errors](#errors) for when it goes away. |
| `notify` | string or object | Not state: a patch that carries it shows a system notification, and the key is never stored. See [Notifications](#notifications). |

## Commands

```json
"commands": {
  "apply":  { "exec": "bin/tool", "args": ["apply"], "stdin": true, "timeout": 60 },
  "ip":     { "shell": "ipconfig getifaddr en0", "capture": "ip" },
  "repair": { "exec": "bin/tool", "args": ["repair"], "privileged": true }
}
```

| Field | Default | Meaning |
| --- | --- | --- |
| `exec` | | Path of a file inside the mod, started directly. Exactly one of `exec` and `shell` is required. |
| `shell` | | Script run by `/bin/sh -c`. |
| `args` | `[]` | Arguments, passed literally. For `shell` they become `$1`, `$2`, … |
| `privileged` | `false` | Run as root, see [Administrator privileges](#administrator-privileges). |
| `stdin` | `false` | Send the [command input](#input) as JSON on standard input. |
| `timeout` | `30` | Seconds (up to 3600) before the command and everything it started are killed. Not applied to the service. |
| `capture` | | State key that receives trimmed standard output as text, instead of treating the output as a patch. |

Command names use letters, digits, `_` and `-`.

A command runs with the mod's folder as its working directory and with this environment and
nothing else:

| Variable | Value |
| --- | --- |
| `TOOLSY_MOD_ID` | The mod's `id`. |
| `TOOLSY_MOD_DIR` | The mod's folder (read-only by convention). |
| `TOOLSY_DATA_DIR` | A folder the mod may write to. It is created before the first command runs. |
| `TOOLSY_EVENT` | `enable`, `disable`, `uninstall`, `refresh`, `service`, `command`, or the [system event](#system-events) that started the command: `launch`, `wake`, `network`, `power`. |
| `TOOLSY_COMMAND` | Name of the command. |
| `TOOLSY_KEY` | State key of the control that started the command, if any. |
| `TOOLSY_VALUE` | New value of that control, or the button's `value`, as text. |
| `TOOLSY_LOCALE` | The user's first preferred language as a lowercase BCP 47 code, such as `ru`, `en-us` or `zh-hans-cn`; compare its first part (`${TOOLSY_LOCALE%%-*}`) to pick a language. Absent when it is not a well-formed code. |
| `TOOLSY_STATE_<key>` | One per state key holding a string, number or boolean, as text (`true`/`false` for booleans). |
| `PATH` | `/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin` — for privileged commands only the system directories. |
| `HOME`, `USER`, `LOGNAME`, `TMPDIR`, `SHELL`, `LANG` | The user's; for privileged commands root's. |

Values never reach a command through string interpolation, so user input cannot inject shell
syntax. Read it from the variables (quoted: `"$TOOLSY_VALUE"`) or from standard input.

### Input

With `"stdin": true` the command receives one JSON document on standard input:

```json
{ "event": "command", "command": "apply", "key": "level", "value": 7, "locale": "ru",
  "state": { "level": 7, "host": "example.com", "enabled": true } }
```

`key` and `value` are present only when a control started the command, `locale` (the value of
`TOOLSY_LOCALE`) only when Toolsy knows it.

### Output

Standard output of a successful command is a **patch**: one JSON object whose keys are merged
into the mod's state. A `null` value removes the key. Empty output changes nothing; output that
is not a JSON object is ignored.

```json
{ "status": "Connected", "level": "ok", "latency": 23.5, "rows": [ { "title": "en0", "value": "up" } ] }
```

With `capture` the trimmed output is stored as a string under that key instead.

A command **fails** when it exits with a non-zero status, is killed by a signal or runs into
its timeout. Its patch is discarded and the mod's `error` becomes, in this order: the `error`
string of a JSON object on standard output, the last non-empty line of standard error, or a
generic message. A bound control that started the command keeps its new value.

#### Notifications

A patch — the output of a command or a line of the service — may carry `notify` to show a
system notification:

```json
{ "status": "Connected", "notify": "Connected to Office VPN" }
{ "notify": { "title": "Backup finished", "body": "42 files, 1.2 GB" } }
```

| Rule | |
| --- | --- |
| Form | A string (the text), or an object with `title` and `body`. Without a `title` the mod's name is the title. |
| State | `notify` is never stored: it cannot be a setting, a bound key or a `capture` key, and `{{notify}}` is always empty. |
| Length | The title is cut to 80 characters, the body to 240. |
| Rate | At most one notification per mod every 5 seconds; others are dropped. An identical notification repeated within a minute is dropped. |
| Permission | Notifications appear only if the user allowed Toolsy to show them; macOS asks the first time. |
| Failures | A failed command's patch is discarded, its `notify` with it. Commands with `capture` cannot notify. |

### Errors

`error` stays until one of these happens:

- the user dismisses it;
- a command the user started (the switch, a button, a bound control) succeeds without setting
  `error` in its patch;
- the error was reported by `refresh` or by the service, and that same source reports again
  without it;
- the error was reported by an [event command](#system-events), and an event command succeeds.

So the automatic `refresh` that follows every command does not wipe the reason a button or the
switch just failed, while a status problem found by `refresh` disappears as soon as `refresh`
finds it resolved.

Commands of one mod never overlap: they run one after another in the order they were started.

## Lifecycle

```json
"lifecycle": {
  "enable": "start",
  "disable": "stop",
  "uninstall": "cleanup",
  "service": "watch",
  "refresh": { "command": "status", "every": 10, "background": false },
  "events": { "wake": "status", "network": "reconnect" }
}
```

Every value names a command.

| Hook | When it runs |
| --- | --- |
| `enable` | The user switches the mod on. On success `enabled` becomes `true`. On failure the switch returns to off. |
| `disable` | The user switches the mod off. On success `enabled` becomes `false`. On failure the switch stays on. |
| `uninstall` | The mod is being removed, after `disable`. Use it to delete what the mod left on the system. |
| `service` | Kept running while the mod is on. See below. |
| `refresh` | Reports current state. Runs when the panel opens, after any other command of the mod finishes, and every `every` seconds (minimum 1) while the panel is open. With `"background": true` the schedule also runs while the panel is closed, as long as the mod is on (or always, for a mod without a switch). |
| `events` | Commands that answer something happening to the Mac. See [System events](#system-events). |

A mod has a main switch if it declares `enable`, `disable` or `service`. A mod with none of
them is a passive widget: it only shows its page.

`enable` and `disable` run only when the user flips the switch, not when Toolsy starts. A mod
whose effect must be re-established after login keeps it alive with a `service`; a mod whose
effect persists on its own (a system setting, a firewall rule) reports the truth from
`refresh` by including `enabled` in its patch.

### System events

`events` maps an event to the command that answers it:

| Event | When it happens |
| --- | --- |
| `launch` | Toolsy started, usually at login. |
| `wake` | The Mac woke from sleep. |
| `network` | The primary network interface or its addresses changed. |
| `power` | The Mac switched between the power adapter and the battery. |

- An event command runs only while the mod is on (always, for a mod without a switch), with
  `TOOLSY_EVENT` set to the event's name.
- It is queued like every other command, so commands of a mod still never overlap. If that
  command is already waiting to run, the event does not queue it again.
- Like `refresh`, a privileged event command is skipped silently while the mod lacks
  administrator access.
- `refresh` runs after it, as after any other command.
- The service command cannot also be an event command. Events alone do not give a mod a switch.

### Service

The service command is started after `enable` succeeds (or directly, if there is no `enable`)
and again whenever Toolsy starts with the mod on. It is stopped — `SIGTERM` to its process
group, `SIGKILL` two seconds later — before `disable` runs and when Toolsy quits.

- Every line it writes to standard output is a patch, applied immediately. This is how a mod
  feeds charts and gauges without polling.
- It is restarted when the user or a command changes one of the mod's settings, so it always
  sees current values. Its own patches do not restart it.
- If it exits with status 0 the mod switches off, exactly as if the user had flipped the switch
  (so `disable` runs). If it exits any other way it is restarted after 1, 2, 4, … up to 60
  seconds and `error` shows why; the delay resets once it has been running for 30 seconds.
- It cannot be `privileged` and cannot use `capture`.

## Interface

`ui` is a list of controls. Each control is an object with a `type`. A mod without `ui` gets a
plain page that shows its status and summary. Three optional fields work on every control:

| Field | Meaning |
| --- | --- |
| `when` | [Expression](#expressions). The control is shown only while it is true. |
| `disabled` | Expression. The control is greyed out and inert while it is true. |
| `help` | Plain text (not a template) shown as a tooltip. |

Text fields marked *template* may contain `{{key}}` placeholders.

A control with a `bind` reads and writes that state key. If the control also names a
`command`, the command runs after each change with `TOOLSY_KEY`/`TOOLSY_VALUE` set. Inputs
cannot be bound to the keys Toolsy manages (`enabled`, `status`, `level`, `error`); displays can
read them. No control can read `notify`, which is never stored.

### Layout

| Type | Fields |
| --- | --- |
| `section` | `title`, `footer` (templates), **`children`**: controls shown as one titled group. `collapsible` (`true`: the user can fold it; needs a `title`), `collapsed` (`true`: a collapsible section starts folded; needs `collapsible`). |
| `row` | **`children`**: 1–4 controls side by side with equal widths. No sections or rows inside. |
| `divider` | — |

Controls may be nested up to four levels deep; a manifest may hold up to 200 controls, counting
those in the `detail` of its [widgets](#widgets).

### Inputs

| Type | Fields |
| --- | --- |
| `toggle` | **`label`** (template), `icon`, **`bind`** (boolean), `command` |
| `slider` | **`label`**, `icon`, **`bind`** (number), **`min`**, **`max`**, `step`, `unit` (suffix such as `"%"`), `command`, `live` (run the command while dragging, not only on release) |
| `stepper` | **`label`**, `icon`, **`bind`** (number), `min`, `max`, `step` (default 1), `unit`, `command` |
| `picker` | `label`, `icon`, **`bind`**, **`options`** (1–32) **or** **`optionsFrom`** (a state key), `style` (`"segmented"` or `"menu"`; by default segmented up to four options), `command` |
| `input` | `label`, `icon`, **`bind`** (string), `placeholder`, `command` (runs when the text is committed with Return or by leaving the field) |
| `button` | **`label`**, `icon`, exactly one of `command`, `open` (an `http(s)` URL) and `copy` (template; clicking copies the rendered text), `value` (handed to the command), `style` (`"normal"`, `"prominent"`, `"destructive"`), `confirm` (question asked first) |

A picker option is `{ "value": …, "label": "…", "icon": "…" }` with a string, number or boolean
value, or just a string that serves as both value and label. With `optionsFrom` the options are
read from that state key, which a command fills with an array of such elements; elements of any
other shape are skipped, and at most 32 are used. Until the key holds an array the picker has no
options.

### Displays

| Type | Fields |
| --- | --- |
| `value` | **`label`**, **`value`** (templates), `icon`, `tint` (template), `copyable` (click to copy) — a "label: value" line. |
| `stat` | **`label`**, **`value`** (templates), `icon`, `tint` (template) — a compact label-over-value fact, meant for `row`s. |
| `text` | **`text`** (template), `style` (`"body"`, `"caption"`, `"title"`, `"mono"`), `tint` (template) |
| `gauge` | **`label`**, `icon`, **`bind`** (number), `min` (0), `max` (100), `unit`, `format`, `style` (`"bar"` or `"ring"`), `tint` (template) |
| `chart` | `label`, **`series`** (1–6 of `{ "bind", "label", "tint" }`), `style` (`"line"`, `"area"`, `"bar"`), `points` (history length, 2–600, default 60), `min`, `max`, `unit`, `format` |
| `list` | **`bind`** (array), `command` (runs when a row is clicked, value = the row's `id`), `empty` (placeholder text), `limit` |

`format` is a filter chain, written as it would follow `|` in a template (`"bytes"`, `"rate"`,
`"fixed:1"`, `"div:1000|fixed:1"`). When set, the gauge's and chart's readouts show the number
through it instead of the number followed by `unit`.

A chart series bound to a **number** records that number each time a patch contains the key and
plots the last `points` samples. A series bound to an **array of numbers** plots the array as
is.

A list row is an object `{ "title", "subtitle", "value", "icon", "tint", "id" }` (only `title`
is required; `id` defaults to the title) or a bare string or number.

### Colours

`tint` accepts a colour name (`red`, `orange`, `yellow`, `green`, `mint`, `teal`, `cyan`,
`blue`, `indigo`, `purple`, `pink`, `brown`, `gray`), a level (`ok`, `warn`, `error`, `off`) or
`#RRGGBB`. Where it is a template, `"tint": "{{level}}"` follows the mod's status.

## Widgets

A mod may offer up to eight tiles for Toolsy's dashboard, next to the built-in ones: a caption,
one headline value and, optionally, a small chart or gauge.

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

| Field | Default | Meaning |
| --- | --- | --- |
| **`id`** | | 1–32 of `a-z 0-9 _ -`, starting with a letter or digit, unique within the mod. Together with the mod's `id` it names the tile in the user's dashboard. |
| `title` | the mod's name | Template. The caption. |
| `icon` | the mod's icon | SF Symbol name. |
| **`value`** | | Template, not blank. The headline. |
| `tint` | the mod's tint | Template resolving to a [colour](#colours). |
| `size` | `"small"` | How many of the dashboard's three columns the tile takes unless the user chooses otherwise: `"small"` 1, `"medium"` 2, `"wide"` 3. |
| `chart` | | A sparkline under the value: **`series`** (1–3 of `{ "bind", "label", "tint" }`), `style` (`"line"`, `"area"`, `"bar"`; default `"area"`), `points` (2–120, default 30), `min`, `max` (`min` < `max` when both are given). Series record history like those of a [chart](#displays). |
| `gauge` | | A level bar under the value: **`bind`** (number), `min` (0), `max` (100), `min` < `max`. |
| `detail` | | Controls shown under the tile while it is expanded, with the rules of `ui` as if they were the `children` of a top-level section. They count toward the 200 controls of the manifest. Without `detail`, a click on the tile opens the mod's page. |
| `when` | | [Expression](#expressions). The tile is on the dashboard only while it is true. |

A widget has at most one of `chart` and `gauge`.

## Localization

`localizations` translates the mod's text into other languages:

```json
"localizations": {
  "ru": { "Keep the display on": "Не выключать дисплей", "Now": "Сейчас", "{{ms}} ms": "{{ms}} мс" }
}
```

| Rule | |
| --- | --- |
| Languages | Keys are language codes: a lowercase BCP 47 language, optionally with a region (`ru`, `de`, `pt-br`). At most 20 languages. |
| Entries | Each language maps a source string, exactly as written in the manifest, to its translation. At most 500 entries per language. Text without an entry stays as written. |
| Choice | Toolsy uses the first of the user's preferred languages that has a table, the most specific first: for `pt-BR` it takes `pt-br`, otherwise `pt`; for `ru-RU`, `ru`. Without a match the manifest is shown as written. |
| What is translated | `name`, `summary`, and in every control and widget the text fields: `label`, `title`, `footer`, `text`, `value`, `placeholder`, `confirm`, `empty`, `unit`, `help`, `copy`, option labels, chart and series labels, widget `title` and `value`. |
| What is not | `id`, commands, `bind`s, icons, tints, expressions, `author`, option values, a button's `value`, and anything a command reports. |
| Templates | A template is translated as a whole string before it is rendered: `"{{ms}} ms"` → `"{{ms}} мс"`. Translations must keep the manifest valid: they are checked at install like the text they replace. |

Commands localise what they report (`status`, list rows, notifications) themselves, with
[`TOOLSY_LOCALE`](#commands).

## Templates and expressions

### Templates

`{{key}}` is replaced by the state value under `key` — text as is, whole numbers without a
decimal point, `true`/`false`, nothing for a missing key. Arrays and objects render as compact
JSON.

A **path** reaches inside arrays and objects: `{{disk.free}}`, `{{rows.0.title}}`. The first
segment is a state key; each further segment (1–64 of `A-Z a-z 0-9 _`) indexes an object by
key or an array by a non-negative integer. A step that finds nothing — a missing key, an index
past the end, a value that is not an object or array — makes the whole path missing, so
`default` applies.

Filters follow a `|` and apply left to right:

| Filter | Input | Output |
| --- | --- | --- |
| `bytes` | bytes | `1.5 GB` |
| `rate` | bytes per second | `1.2 MB/s` |
| `bitrate` | bytes per second | `12.4 Mbit/s` (bit/s, kbit/s, Mbit/s, Gbit/s) |
| `percent` | 0–100 | `42%` |
| `duration` | seconds | `45s`, `3m 20s`, `2h 05m`, `1d 4h` |
| `round` | number | nearest whole number |
| `fixed:N` | number | exactly N decimals (0–10) |
| `number` | number | digits grouped for the user's locale, at most 2 decimals: `1,234.5`, `1 234,5` |
| `time` | Unix seconds | short time of day in the user's locale and time zone: `13:33`, `1:33 PM` |
| `date` | Unix seconds | short date: `16.11.2025`, `11/16/2025` |
| `ago` | Unix seconds | relative time: `5 min. ago`, `now`, `in 1 min.` |
| `mul:N`, `div:N`, `add:N` | number | the number times, divided by, plus N (`-273.15`, `0.5`; `div` not by 0) |
| `upper`, `lower` | string | the text in upper or lower case |
| `truncate:N` | string | cut to N characters (1–500) ending in `…`; shorter text stays |
| `count` | array, object, string | number of elements, or of characters |
| `join:SEP` | array | the string, number and boolean elements joined by SEP (`join` alone: `, `) |
| `either:A:B` | anything | A if the value is truthy (as in [expressions](#expressions)), else B. B may be empty and may contain `:`. |
| `default:TEXT` | anything | `TEXT` if the value is missing or empty |

Each filter acts on the kind of value it is made for and passes anything else through
unchanged. In particular numeric filters leave non-numbers untouched (a numeric string such as
`"12"` is not a number), so `{{ping|fixed:1|default:—}}` shows a dash until the first
measurement arrives. `bytes`, `rate` and `bitrate` use decimal units with at most one decimal,
`percent` rounds to a whole number. Arithmetic that overflows renders nothing. Texts of
`default`, `join` and `either` are kept exactly as written, spaces included; they cannot contain
`|` or `}}`. An unknown filter or a bad argument is an error at install time that names the field.

### Expressions

`when` and `disabled` take a small boolean expression over state:

```
enabled
!enabled
mode == 'manual' && level >= 3
(status == "Active" || retries < 5) && !error
used / total * 100 > 80
name contains 'Air' && rows.0.title != null
```

Operands are state keys and [paths](#templates) (`disk.free`), numbers (also negative), quoted
strings without escape sequences, `true`, `false` and `null` (so `true`, `false`, `null` and
`contains` cannot be used as keys here). Operators, loosest first:

| Level | Operators |
| --- | --- |
| or | `\|\|` |
| and | `&&` |
| not | `!` — applies to everything up to the next `&&` or `\|\|`: `!a == b` means `!(a == b)` |
| comparison | one of `==`, `!=`, `<`, `<=`, `>`, `>=`, `contains`; a second one needs parentheses |
| sum | `+`, `-`, left to right |
| product | `*`, `/`, `%` (remainder, with the sign of the left side), left to right |

Parentheses group. A bare operand counts as true unless it is missing, `null`, `false`, `0` or
empty.

- Ordering comparisons are true only between two numbers. `==` and `!=` compare any values.
- Arithmetic works on numbers only. With anything else, or when dividing (or taking the
  remainder) by zero, the result is `null`, and `null` stays `null` through further arithmetic.
- `a contains b` is true when `a` is a string that contains the string `b` (case-sensitive), or
  an array with an element equal to the string, number or boolean `b`. Anything else is false.
- A `-` right before a digit starts a negative number unless it follows a value: `a-1` and
  `a - 1` subtract, `a > -1` compares with minus one. Only numbers can be negated: write
  `0 - a`, not `-a`.

## Administrator privileges

A command marked `"privileged": true` runs as root. Toolsy does this without asking for a
password each time:

1. The first time a mod with privileged commands is installed, Toolsy installs a small helper.
   That is the only moment macOS asks for an administrator password.
2. Installing the mod is what approves it. The confirmation lists the commands that will run as
   root, and the helper copies the very files being installed into a store only root can read.
3. From then on the helper runs the privileged commands **from that copy**, exactly as installed.
   If the installed files are changed afterwards, Toolsy stops running the mod's privileged
   commands until the mod is installed again from a package; nothing is ever approved from the
   folder of an installed mod.

What this means for a mod author:

- Treat standard input and `TOOLSY_*` variables (`TOOLSY_LOCALE` included) as untrusted and
  validate them. They are data from a user-level process, and your program acts on them as root.
- Only one-shot commands can be privileged; the service cannot.
- `TOOLSY_MOD_DIR` is the root-owned copy and `TOOLSY_DATA_DIR` is a root-owned folder. `PATH`
  holds system directories only, so call tools by absolute path or ship them in the mod.
- A mod that declares privileged commands shows a clear warning before it is installed, listing
  the commands.
- Keep the mod's folder as it was installed and write only to `TOOLSY_DATA_DIR`: a mod that
  changes its own files loses its privileged commands.
- While a privileged command runs, the mod cannot be updated or removed. Keep them short.

## Examples

A widget with no switch — one manifest, no other files:

```json
{
  "schema": 1, "id": "local-ip", "name": "Local IP", "version": "1.0", "icon": "network",
  "commands": { "read": { "shell": "ipconfig getifaddr en0 || echo offline", "capture": "ip" } },
  "lifecycle": { "refresh": { "command": "read", "every": 30 } },
  "ui": [ { "type": "value", "label": "Wi-Fi address", "value": "{{ip|default:…}}", "copyable": true } ]
}
```

A service that feeds a chart:

```json
{
  "schema": 1, "id": "ping", "name": "Ping", "version": "1.0", "icon": "dot.radiowaves.left.and.right",
  "settings": { "host": "1.1.1.1" },
  "commands": { "watch": { "exec": "watch.sh" } },
  "lifecycle": { "service": "watch" },
  "ui": [
    { "type": "input", "label": "Host", "bind": "host" },
    { "type": "chart", "label": "Latency", "series": [ { "bind": "ms" } ], "unit": " ms", "style": "area" },
    { "type": "value", "label": "Now", "value": "{{ms|fixed:1|default:—}} ms" }
  ]
}
```

```sh
#!/bin/sh
# watch.sh — one JSON patch per line
while :; do
  ms=$(ping -c 1 -t 2 "$TOOLSY_STATE_host" 2>/dev/null | sed -n 's/.*time=\([0-9.]*\).*/\1/p')
  if [ -n "$ms" ]; then
    echo "{\"ms\": $ms, \"status\": \"$ms ms\", \"level\": \"ok\"}"
  else
    echo '{"status": "No reply", "level": "warn"}'
  fi
  sleep 2
done
```

A mod without a switch that offers a dashboard tile, answers system events, notifies, and
speaks Russian:

```json
{
  "schema": 1, "id": "network-watch", "name": "Network watch", "version": "1.0", "icon": "network",
  "summary": "Shows the Mac's address and tells when it changes",
  "commands": {
    "read": { "shell": "printf '{\"address\": \"%s\"}' \"$(ipconfig getifaddr en0)\"" },
    "changed": { "exec": "changed.sh", "timeout": 10 }
  },
  "lifecycle": { "events": { "launch": "read", "wake": "changed", "network": "changed" } },
  "widgets": [
    {
      "id": "address", "title": "Address", "value": "{{address|default:Offline}}", "tint": "{{address|either:ok:off}}",
      "detail": [
        { "type": "row", "children": [
          { "type": "stat", "label": "Changed", "value": "{{changedAt|ago|default:—}}" },
          { "type": "stat", "label": "Changes", "value": "{{changes|default:0}}" }
        ] },
        { "type": "button", "label": "Copy address", "icon": "doc.on.doc", "copy": "{{address}}", "disabled": "!address" }
      ]
    }
  ],
  "ui": [
    { "type": "value", "label": "Address", "value": "{{address|default:Offline}}", "copyable": true },
    { "type": "section", "title": "Details", "collapsible": true, "collapsed": true, "children": [
      { "type": "value", "label": "Changed", "value": "{{changedAt|time|default:—}}", "help": "When the address last changed" },
      { "type": "value", "label": "Changes", "value": "{{changes|default:0}}", "help": "Since Toolsy started" }
    ] }
  ],
  "localizations": {
    "ru": {
      "Network watch": "Сеть", "Shows the Mac's address and tells when it changes": "Показывает адрес Mac и сообщает, когда он меняется",
      "Address": "Адрес", "{{address|default:Offline}}": "{{address|default:Нет сети}}", "Changed": "Изменился",
      "Changes": "Изменений", "Copy address": "Скопировать адрес", "Details": "Подробности",
      "When the address last changed": "Когда адрес изменился в последний раз", "Since Toolsy started": "С запуска Toolsy"
    }
  }
}
```

```sh
#!/bin/sh
# changed.sh — runs on wake and whenever the network changes
address=$(ipconfig getifaddr en0)
[ "$address" = "$TOOLSY_STATE_address" ] && exit 0      # empty output changes nothing
changes=$(( ${TOOLSY_STATE_changes:-0} + 1 ))
case ${TOOLSY_LOCALE%%-*} in
  ru) text="Новый адрес: ${address:-нет сети}" ;;
  *)  text="New address: ${address:-offline}" ;;
esac
printf '{"address": "%s", "changedAt": %s, "changes": %s, "notify": "%s"}\n' "$address" "$(date +%s)" "$changes" "$text"
```

`Mods/` in the Toolsy repository holds complete mods: `showcase` exercises every control, and
`vpn-protector` is a privileged mod with a compiled helper program.
