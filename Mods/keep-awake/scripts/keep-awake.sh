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
    /usr/bin/jq -n -c --argjson enabled "$1" --argjson until "$2" --arg status "$status" --arg level "$level" \
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
