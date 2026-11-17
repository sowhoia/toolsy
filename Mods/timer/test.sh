#!/bin/sh
# Runs every command of mod.json the way Toolsy does (same environment variables, mod folder as
# working directory) and checks the patches, including a few seconds of the service. Every
# service the test starts runs in a process group of its own, which is killed on exit.
set -eu
cd "$(dirname "$0")"
mod=$(pwd)
jq=/usr/bin/jq
id=$($jq -r .id mod.json)
data=$(mktemp -d)
services=
# shellcheck disable=SC2154 # pid is the variable of the trap's own loop
trap 'for pid in $services; do kill -TERM -- "-$pid" 2>/dev/null || true; done; rm -rf "$data"' EXIT
# Background jobs get process groups of their own, as Toolsy gives its services.
set -m
failures=0

problem() {
    printf 'FAIL %s\n' "$*" >&2
    failures=$((failures + 1))
}

# environment COMMAND [VAR=VALUE…]: sets "$@" to the environment Toolsy gives COMMAND: the settings'
# defaults and `enabled` as TOOLSY_STATE_*, overridden by the extra assignments.
environment() {
    name=$1
    shift
    # shellcheck disable=SC2046 # one assignment per line; the callers set IFS to a newline
    set -- $($jq -r '(.settings // {}) | to_entries[] | "TOOLSY_STATE_\(.key)=\(.value)"' mod.json) TOOLSY_STATE_enabled=false "$@"
    set -- PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin HOME="$HOME" LANG=en_US.UTF-8 \
        TOOLSY_MOD_ID="$id" TOOLSY_MOD_DIR="$mod" TOOLSY_DATA_DIR="$data" TOOLSY_EVENT=command \
        TOOLSY_COMMAND="$name" "$@"
    printf '%s\n' "$@"
}

# run COMMAND [VAR=VALUE…]: runs a command of mod.json; leaves stdout, stderr and status in $data.
# shellcheck disable=SC2016 # $name in the jq programs is jq's variable
run() {
    name=$1
    program=$($jq -r --arg name "$name" '.commands[$name].exec' mod.json)
    args=$($jq -r --arg name "$name" '(.commands[$name].args // [])[]' mod.json)
    status=0
    # One assignment per line; no value in this test contains a newline.
    old_ifs=$IFS
    IFS='
'
    # shellcheck disable=SC2046,SC2086 # split into one word per line on purpose
    env -i $(environment "$@") "$mod/$program" $args >"$data/out" 2>"$data/err" </dev/null || status=$?
    IFS=$old_ifs
}

# expect CHECK COMMAND [VAR=VALUE…]: the command succeeds and prints one JSON object that satisfies
# the jq expression CHECK.
expect() {
    check=$1
    shift
    label="$*"
    run "$@"
    if [ "$status" -ne 0 ]; then
        problem "$label: exit $status: $(tail -n 1 "$data/err")"
    elif ! $jq -e -s "length == 1 and (.[0] | type) == \"object\" and (.[0] | $check)" "$data/out" >/dev/null 2>&1; then
        problem "$label: expected $check, got: $(cat "$data/out")"
    else
        printf 'ok   %s → %s\n' "$label" "$($jq -c . "$data/out")"
    fi
}

# expect_nothing COMMAND [VAR=VALUE…]: the command succeeds and changes nothing.
expect_nothing() {
    label="$*"
    run "$@"
    if [ "$status" -ne 0 ] || [ -s "$data/out" ]; then
        problem "$label: expected no output, got exit $status: $(cat "$data/out" "$data/err")"
    else
        printf 'ok   %s → nothing\n' "$label"
    fi
}

# expect_failure COMMAND [VAR=VALUE…]: the command fails with a message on stderr.
expect_failure() {
    label="$*"
    run "$@"
    message=$(grep -v '^[[:space:]]*$' "$data/err" | tail -n 1 || true)
    if [ "$status" -eq 0 ]; then
        problem "$label: expected a failure, got exit 0"
    elif [ -z "$message" ]; then
        problem "$label: failed without a message"
    else
        printf 'ok   %s → exit %s: %s\n' "$label" "$status" "$message"
    fi
}

# start_service [VAR=VALUE…]: starts the service in the background with the mod on; its PID, which
# is also its process group, is in $service.
start_service() {
    old_ifs=$IFS
    IFS='
'
    # shellcheck disable=SC2046 # split into one word per line on purpose
    env -i $(environment wait TOOLSY_STATE_enabled=true "$@" TOOLSY_EVENT=service) "$mod/scripts/timer.sh" wait >"$data/out" 2>"$data/err" </dev/null &
    service=$!
    IFS=$old_ifs
    services="$services $service"
}

# exits_within SECONDS: whether the service exits with status 0 within SECONDS.
exits_within() {
    i=0
    while kill -0 "$service" 2>/dev/null; do
        [ "$i" -lt $(($1 * 10)) ] || return 1
        sleep 0.1
        i=$((i + 1))
    done
    wait "$service"
}

now=$(date +%s)
# shellcheck disable=SC2016 # $(x) and `y` are meant literally: text that must never run
odd=$(printf 'Ли "Ко" \\ \t\001 \377 🙂 $(x) `y`')
running="TOOLSY_STATE_enabled=true"

# Before the first start: a whole work phase, nothing running.
expect '.enabled == false and .phase == "work" and .left == 1500 and .clock == "25:00" and .progress == 0 and .status == "Ready to start" and .level == "off" and (has("notify") | not)' show TOOLSY_EVENT=refresh
expect '.clock == "1:30:00" and .phaseName == "Работа" and .status == "Готов к запуску"' show TOOLSY_STATE_workMinutes=90 TOOLSY_LOCALE=ru-ru
expect '.status == "Ready to start"' show TOOLSY_LOCALE="$odd"

# Start, pause, resume, reset.
expect "(.endsAt - $now | . >= 1500 and . <= 1502) and .enabled and .pausedLeft == 0 and .status == \"Work · 25:00\" and .level == \"ok\"" start
expect "(.endsAt - $now | . >= 600 and . <= 602) and .enabled and .pausedLeft == 0" start TOOLSY_STATE_pausedLeft=600
expect ".endsAt == $((now + 100)) and .enabled" start $running TOOLSY_STATE_endsAt=$((now + 100))
expect '.enabled == false and .endsAt == 0 and (.pausedLeft | . >= 598 and . <= 600) and .level == "warn" and (.status | startswith("Paused · Work "))' pause $running TOOLSY_STATE_endsAt=$((now + 600))
expect '.enabled == false and .pausedLeft == 300 and .clock == "05:00" and .progress == 80' pause TOOLSY_STATE_pausedLeft=300
expect '.enabled == false and .phase == "work" and .endsAt == 0 and .pausedLeft == 0 and .clock == "25:00"' reset $running TOOLSY_STATE_phase=break TOOLSY_STATE_endsAt=$((now + 100))

# A running phase: time left and progress come from the wall clock.
expect '.enabled and (.progress | . >= 49 and . <= 50) and (.left | . >= 749 and . <= 750)' show $running TOOLSY_STATE_endsAt=$((now + 750))
expect '.phase == "break" and (.status | startswith("Break · 0"))' show $running TOOLSY_STATE_phase=break TOOLSY_STATE_endsAt=$((now + 200))

# A phase that ended meanwhile (during sleep, or while Toolsy was not running) is settled and
# announced: work is followed by a break that starts when the work ended, and the timer stops
# after the break.
expect ".phase == \"break\" and .endsAt == $((now - 10 + 300)) and .enabled and .notify.title == \"Time for a break\" and .notify.body == \"Work phase done. Take 5 min.\"" show TOOLSY_EVENT=wake $running TOOLSY_STATE_endsAt=$((now - 10))
expect '.phase == "work" and .endsAt == 0 and .enabled == false and .clock == "25:00" and .notify.title == "Break is over"' show TOOLSY_EVENT=wake $running TOOLSY_STATE_phase=break TOOLSY_STATE_endsAt=$((now - 1))
expect '.phase == "work" and .enabled == false and .notify.title == "Break is over"' show $running TOOLSY_STATE_endsAt=$((now - 3600))
expect '.notify.title == "Пора отдохнуть" and .notify.body == "Работа завершена. Отдохните 5 мин."' show $running TOOLSY_STATE_endsAt=$((now - 1)) TOOLSY_LOCALE=ru
expect '.phase == "break" and .enabled == false and (.pausedLeft | . >= 297 and . <= 299) and .notify.title == "Time for a break"' pause $running TOOLSY_STATE_endsAt=$((now - 1))
expect '.phase == "work" and .enabled == false and (has("notify") | not)' show TOOLSY_STATE_endsAt=$((now - 1))

# Settings that are not what the manifest allows are refused with a message.
expect_failure show TOOLSY_STATE_workMinutes=0
expect_failure show TOOLSY_STATE_workMinutes="$odd"
expect_failure show TOOLSY_STATE_breakMinutes=61
expect_failure show TOOLSY_STATE_phase="$odd"
expect_failure show TOOLSY_STATE_endsAt=-1
expect_failure show TOOLSY_STATE_pausedLeft=99999 TOOLSY_LOCALE=ru
grep -q 'Осталось' "$data/err" || problem "a Russian error is expected, got: $(cat "$data/err")"
expect_failure start TOOLSY_STATE_endsAt='1; echo'

# The service sleeps until the phase ends, then reports the break and notifies.
start_service TOOLSY_STATE_breakMinutes=1 TOOLSY_STATE_endsAt=$((now + 2))
sleep 1
[ ! -s "$data/out" ] || problem "wait: reported before the phase ended: $(cat "$data/out")"
sleep 2
if $jq -e -s "length == 1 and (.[0] | .phase == \"break\" and .endsAt == $((now + 62)) and .enabled and .notify.title == \"Time for a break\")" "$data/out" >/dev/null 2>&1; then
    echo "ok   wait for the end of work → $(cat "$data/out")"
else
    problem "wait for the end of work: got $(cat "$data/out") $(cat "$data/err")"
fi
kill -0 "$service" 2>/dev/null || problem "wait: stopped during the break"
kill -TERM -- "-$service"
wait "$service" 2>/dev/null || true

# Phases that ended while the service was not running are settled at once; after the break the
# service exits with status 0, which switches the mod off.
start_service TOOLSY_STATE_phase=break TOOLSY_STATE_endsAt=$((now - 5))
if exits_within 3 && $jq -e -s 'length == 1 and (.[0] | .enabled == false and .phase == "work" and .notify.title == "Break is over")' "$data/out" >/dev/null 2>&1; then
    echo "ok   wait after the break ended → $(cat "$data/out"), exit 0"
else
    problem "wait after the break ended: expected one patch and exit 0, got $(cat "$data/out") $(cat "$data/err")"
fi
start_service TOOLSY_STATE_enabled=false
if exits_within 3 && [ ! -s "$data/out" ]; then
    echo "ok   wait while stopped → exit 0"
else
    problem "wait while stopped: expected no output and exit 0, got $(cat "$data/out") $(cat "$data/err")"
fi

if [ "$failures" -ne 0 ]; then
    echo "$failures check(s) failed" >&2
    exit 1
fi
echo "all checks passed"
