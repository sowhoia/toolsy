# Showcase

A Toolsy mod that puts every part of the mod format (`docs/MOD_FORMAT.md`) on one page, each used the
way it is meant to be used: look here for a working example of anything the format offers. It
changes nothing on the system and needs no administrator access; it only reads readings with
standard macOS tools (`sysctl`, `netstat`, `ps`, `scutil --get ComputerName`, `sw_vers`, `jq`).

| Where | What it shows |
| --- | --- |
| **System now** | The service (`scripts/service.sh`) sends a patch every second while the mod is on: ring gauges (one with a `format`), `stat` rows, values with `fixed`, `bytes`, `percent`, `rate` and `bitrate`, an area chart and a line chart with a `format`, an expression with arithmetic and parentheses, `help`. The switch's `enable` and `disable` hooks are `shell` commands. |
| **Wave** | Persisted settings (segmented picker with icons, slider, stepper, toggle) that restart the service when they change; a two-series line chart and a bar gauge. |
| **Processes** | The refresh command (`scripts/refresh.sh`, every 5 seconds): a list whose rows run a command, a bar chart from an array, a menu picker whose options are plain strings, a template path (`processes.0.title`). |
| **Buttons and input** | A text field with a command, `contains`, buttons of every style with `confirm`, `disabled` and `value`, `%` in an expression, a live slider, a picker fed from state (`optionsFrom`), a slow and a failing command (with a JSON `error`), `capture`, `stdin`, a link. |
| **Events and notifications** | `launch`, `wake`, `network` and `power` events, counted while the mod is on; notifications as text and with a title. |
| **Text and values** | Every text style, a copyable value, a button that copies a template. |
| **Template filters** | A collapsed section with the remaining filters: `date`, `time`, `ago`, `div`, `mul`, `add`, `round`, `number`, `upper`, `lower`, `truncate`, `count`, `join`, `either`. |
| Dashboard | Four widgets: small ones with a chart and with a gauge, shown only while the mod is on; a medium one whose detail has buttons; a wide one with a two-series chart and settings in its detail. |

The manifest is written in English with a Russian table under `localizations`; the scripts translate
what they report with `TOOLSY_LOCALE`.

```sh
./test.sh     # runs every command as Toolsy does and checks the output with jq
./build.sh    # build/showcase.toolsymod
```

`scripts/build-mods.sh` at the repository root builds the mod and checks it with Toolsy's validator
(`toolsy-mod validate`).
