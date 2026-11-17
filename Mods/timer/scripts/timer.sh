#!/bin/sh
# Focus Timer's commands; $1 names one.
#
# The timer is three settings, so it survives quitting Toolsy: `phase` (work or break), `endsAt`
# (when the running phase ends, in Unix seconds; 0 while stopped) and `pausedLeft` (seconds left
# in a paused phase; 0 when the phase has not started). Time left is always worked out from the
# wall clock, never by counting ticks, so it stays right across sleep and restarts.
#
# Every command first settles the phases that ended meanwhile. That is deterministic (a break
# starts exactly when its work phase ended), so the service and the commands that may settle the
# same ending at once report the same patch, and the repeated notification is dropped by Toolsy.
#
# Patches are built with jq (`jq -n --arg …`), which escapes whatever text it is given, so nothing a
# command reports can break the JSON.
set -eu

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

work=${TOOLSY_STATE_workMinutes-}
rest=${TOOLSY_STATE_breakMinutes-}
phase=${TOOLSY_STATE_phase-}
ends=${TOOLSY_STATE_endsAt-}
paused=${TOOLSY_STATE_pausedLeft-}
running=${TOOLSY_STATE_enabled-false}
require_whole "$work" 1 180 "$(say "Work" "Работа")"
require_whole "$rest" 1 60 "$(say "Break" "Перерыв")"
require_whole "$ends" 0 9999999999 "$(say "End of the phase" "Конец этапа")"
require_whole "$paused" 0 10800 "$(say "Time left" "Осталось")"
case $phase in
work | break) ;;
*) fail "$(say "Unknown phase" "Неизвестный этап") «${phase}»" ;;
esac
# Stopped means no end: a paused phase keeps its time left in pausedLeft instead.
if [ "$running" != true ] || [ "$ends" -eq 0 ]; then running=false ends=0; fi
now=$(date +%s)

length() {
    if [ "$phase" = work ]; then echo $((work * 60)); else echo $((rest * 60)); fi
}

# Moves through the phases that ended by now. Work is followed by a break; after the break the
# timer stops, ready for the next work phase. Sets `notice` to the notification for the last ending.
notice=null
settle() {
    while [ "$running" = true ] && [ "$now" -ge "$ends" ]; do
        if [ "$phase" = work ]; then
            phase=break ends=$((ends + rest * 60))
            notice=$(/usr/bin/jq -n -c --arg title "$(say "Time for a break" "Пора отдохнуть")" \
                --arg body "$(say "Work phase done. Take $rest min." "Работа завершена. Отдохните $rest мин.")" '{title: $title, body: $body}')
        else
            phase=work ends=0 paused=0 running=false
            notice=$(/usr/bin/jq -n -c --arg title "$(say "Break is over" "Перерыв окончен")" \
                --arg body "$(say "Start the next work phase when you are ready." "Начните следующий этап работы, когда будете готовы.")" '{title: $title, body: $body}')
        fi
    done
}

# Prints the whole patch: the timer's settings, the switch, and what the page shows.
emit() {
    if [ "$running" = true ]; then
        left=$((ends - now))
    elif [ "$paused" -gt 0 ]; then
        left=$paused
    else
        left=$(length)
    fi
    total=$(length)
    progress=$((100 * (total - left) / total))
    [ "$progress" -ge 0 ] || progress=0
    if [ "$left" -ge 3600 ]; then
        clock=$(printf '%d:%02d:%02d' $((left / 3600)) $((left % 3600 / 60)) $((left % 60)))
    else
        clock=$(printf '%02d:%02d' $((left / 60)) $((left % 60)))
    fi
    if [ "$phase" = work ]; then name=$(say "Work" "Работа"); else name=$(say "Break" "Перерыв"); fi
    if [ "$running" = true ]; then
        status="$name · $clock" level=ok
    elif [ "$paused" -gt 0 ]; then
        status="$(say "Paused" "Пауза") · $name $clock" level=warn
    else
        status=$(say "Ready to start" "Готов к запуску") level=off
    fi
    /usr/bin/jq -n -c --arg phase "$phase" --argjson endsAt "$ends" \
        --argjson pausedLeft "$paused" --argjson enabled "$running" --argjson left "$left" \
        --argjson progress "$progress" --arg clock "$clock" --arg phaseName "$name" \
        --arg status "$status" --arg level "$level" --argjson notify "$notice" '
        {phase: $phase, endsAt: $endsAt, pausedLeft: $pausedLeft, enabled: $enabled, left: $left,
         progress: $progress, clock: $clock, phaseName: $phaseName, status: $status, level: $level}
        + if $notify then {notify: $notify} else {} end'
}

settle
case ${1-} in
start) # The main switch and the Start button: resumes a paused phase or starts a new one.
    if [ "$running" = false ]; then
        if [ "$paused" -gt 0 ]; then ends=$((now + paused)); else ends=$((now + $(length))); fi
        paused=0 running=true
    fi
    emit
    ;;
pause) # The main switch and the Pause button.
    if [ "$running" = true ]; then
        paused=$((ends - now)) ends=0 running=false
    fi
    emit
    ;;
reset) # Back to the start of a work phase.
    phase=work ends=0 paused=0 running=false
    emit
    ;;
show) # Refresh, and the wake event: a phase that ended during sleep is settled at once.
    emit
    ;;
wait) # The service: sleeps until the running phase ends, then reports and notifies.
    while :; do
        [ "$notice" = null ] || emit
        # The cycle is complete: exiting with status 0 switches the mod off.
        [ "$running" = true ] || exit 0
        # Sleep of the Mac may stretch this; the wake event settles that phase on time instead.
        sleep $((ends - now))
        now=$(date +%s) notice=null
        settle
    done
    ;;
*)
    fail "$(say "Unknown command" "Неизвестная команда") «${1-}»"
    ;;
esac
