import Foundation

/// The mods `new` writes. Each is the smallest idiomatic mod of its kind, because authors (and models) copy
/// them: POSIX sh with macOS tools only, `TOOLSY_*` values quoted, JSON printed safely, comments where the
/// contract is easy to get wrong, English text with a Russian table.
enum StarterTemplate: String, CaseIterable {
    case basic, `switch`, service, widget

    /// The files of a mod named `name` with id `id`: path, contents, executable bit.
    func files(id: String, name: String) -> [(path: String, contents: String, executable: Bool)] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        // A String always encodes.
        let quotedName = String(decoding: (try? encoder.encode(name)) ?? Data(), as: UTF8.self)
        func fill(_ text: String) -> String {
            text.replacing("__ID__", with: id).replacing("__NAME__", with: name)
        }
        return [("mod.json", manifest.replacing("\"__NAME__\"", with: quotedName).replacing("__ID__", with: id), false)]
            + scripts.map { ($0.path, $0.contents, true) }
            + [("README.md", fill(readme), false)]
    }

    private var manifest: String {
        switch self {
        case .basic: Self.basicManifest
        case .switch: Self.switchManifest
        case .service: Self.serviceManifest
        case .widget: Self.widgetManifest
        }
    }

    private var scripts: [(path: String, contents: String)] {
        switch self {
        case .basic: [("check.sh", Self.shellHeader + Self.basicScript)]
        case .switch: [("folder.sh", Self.shellHeader + Self.switchScript)]
        case .service: [("watch.sh", Self.shellHeader + Self.serviceScript)]
        case .widget: [("battery.sh", Self.shellHeader + Self.widgetScript)]
        }
    }

    private var readme: String {
        let (what, tries): (String, String) = switch self {
        case .basic: (
            "a page with a value that `refresh` keeps fresh, a setting and a button. `check.sh` reports how long the Mac has been running and turns the status yellow after the number of days the stepper sets.",
            """
            toolsy-mod preview . --state '{"uptime": 93784, "bootedAt": 1731700000, "status": "Fine", "level": "ok"}'
            toolsy-mod run . check
            toolsy-mod run . check --key days --value 1 --locale ru
            """)
        case .switch: (
            "a switch whose effect lasts on its own. Switched on, `folder.sh hide` hides the chosen folder from Finder; `show` reverses it; `status`, the refresh command, reports with `enabled` whether the folder really is hidden, so the switch follows changes made outside Toolsy.",
            """
            mkdir -p /tmp/__ID__-test
            toolsy-mod run . hide --state '{"folder": "/tmp/__ID__-test"}'
            toolsy-mod run . status --state '{"folder": "/tmp/__ID__-test"}'
            toolsy-mod run . show --state '{"folder": "/tmp/__ID__-test"}'
            toolsy-mod run . hide          # fails: no folder is chosen yet
            toolsy-mod preview . --state '{"enabled": true, "folder": "~/Private", "status": "Hidden: Private", "level": "ok"}'
            """)
        case .service: (
            "a service: `watch.sh` runs while the mod is on and prints the load average as a patch every few seconds, which feeds the chart and the status.",
            """
            toolsy-mod run . watch --for 5
            toolsy-mod run . watch --for 5 --state '{"interval": 1}'
            toolsy-mod preview . --state '{"enabled": true, "load": 1.52, "cores": 8, "status": "Normal", "level": "ok"}'
            """)
        case .widget: (
            "a dashboard widget without a switch. `battery.sh read` reads the battery for the widget's value and gauge; it runs on a schedule and when the Mac starts Toolsy or wakes. `battery.sh changed` answers the `power` event and announces the new power source with a notification.",
            """
            toolsy-mod run . read
            toolsy-mod run . changed --event power
            toolsy-mod run . changed --event power --state '{"announce": false}'
            toolsy-mod preview . --state '{"percent": 42, "source": "Battery", "remaining": "3:10", "level": "ok"}' --language ru
            """)
        }
        return """
            # __NAME__

            A Toolsy mod made from the `\(rawValue)` template of `toolsy-mod new`: \(what)

            `mod.json` is the manifest (the format is specified in MOD_FORMAT.md); the script does the work.
            `toolsy-mod` ships inside Toolsy as `/Applications/Toolsy.app/Contents/Helpers/toolsy-mod`.

            Try it from this folder, without installing it:

            ```sh
            toolsy-mod validate .
            \(tries)
            ```

            Pack it and install the file by dropping it on the Toolsy menu bar icon:

            ```sh
            toolsy-mod pack . -o ../__ID__.toolsymod
            ```

            """
    }

    // MARK: - Shell

    /// What every script starts with: strict mode and the two helpers the templates share.
    private static let shellHeader = #"""
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

        """#

    // MARK: - basic

    private static let basicManifest = #"""
        {
          "schema": 1,
          "id": "__ID__",
          "name": "__NAME__",
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

        """#

    private static let basicScript = #"""

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

        """#

    // MARK: - switch

    private static let switchManifest = #"""
        {
          "schema": 1,
          "id": "__ID__",
          "name": "__NAME__",
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

        """#

    private static let switchScript = #"""

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

        """#

    // MARK: - service

    private static let serviceManifest = #"""
        {
          "schema": 1,
          "id": "__ID__",
          "name": "__NAME__",
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

        """#

    private static let serviceScript = #"""

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

        """#

    // MARK: - widget

    private static let widgetManifest = #"""
        {
          "schema": 1,
          "id": "__ID__",
          "name": "__NAME__",
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

        """#

    private static let widgetScript = #"""

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

        """#
}
