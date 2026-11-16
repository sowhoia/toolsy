#!/bin/sh
# Runs every command of mod.json the way Toolsy does (same environment variables, mod folder as
# working directory) and checks the patches. The service starts caffeinate for at most a few
# seconds; every process the test starts is killed by its PID on exit.
set -eu
cd "$(dirname "$0")"
mod=$(pwd)
jq=/usr/bin/jq
id=$($jq -r .id mod.json)
data=$(mktemp -d)
services=
trap 'for pid in $services; do kill "$pid" 2>/dev/null || true; done; rm -rf "$data"' EXIT
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
    set -- $($jq -r '(.settings // {}) | to_entries[] | "TOOLSY_STATE_\(.key)=\(.value)"' mod.json) TOOLSY_STATE_enabled=false "$@"
    set -- PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin HOME="$HOME" LANG=en_US.UTF-8 \
        TOOLSY_MOD_ID="$id" TOOLSY_MOD_DIR="$mod" TOOLSY_DATA_DIR="$data" TOOLSY_EVENT=command \
        TOOLSY_COMMAND="$name" "$@"
    printf '%s\n' "$@"
}

# run COMMAND [VAR=VALUE…]: runs a command of mod.json; leaves stdout, stderr and status in $data.
run() {
    name=$1
    program=$($jq -r --arg name "$name" '.commands[$name].exec' mod.json)
    args=$($jq -r --arg name "$name" '(.commands[$name].args // [])[]' mod.json)
    status=0
    # One assignment per line; no value in this test contains a newline.
    old_ifs=$IFS
    IFS='
'
    # shellcheck disable=SC2046 # split into one word per line on purpose
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

# start_service [VAR=VALUE…]: starts the service in the background; its PID is in $service.
start_service() {
    old_ifs=$IFS
    IFS='
'
    # shellcheck disable=SC2046 # split into one word per line on purpose
    env -i $(environment hold "$@" TOOLSY_EVENT=service) "$mod/scripts/keep-awake.sh" hold >"$data/out" 2>"$data/err" </dev/null &
    service=$!
    IFS=$old_ifs
    services="$services $service"
    # The script replaces itself with caffeinate under the same PID.
    sleep 0.5
}

now=$(date +%s)
odd=$(printf 'Ли "Ко" \\ \t\001 \377 🙂 $(x) `y`')

# The switch and the buttons: `until` is when the hold ends, 0 for no end.
expect ".enabled and (.until - $now | . >= 3600 and . <= 3605) and .status == \"1 h 00 min left\" and .level == \"ok\"" start
expect '.enabled and .until == 0 and .status == "On"' start TOOLSY_STATE_duration=0
expect '.status == "30 min left"' start TOOLSY_STATE_duration=30
expect '.status == "Ещё 2 ч 00 мин"' start TOOLSY_STATE_duration=120 TOOLSY_LOCALE=ru-ru
expect '.status == "Включено"' start TOOLSY_STATE_duration=0 TOOLSY_LOCALE=ru
expect '.status == "On"' start TOOLSY_STATE_duration=0 TOOLSY_LOCALE="$odd"
expect '.enabled == false and .until == 0 and .status == "Off" and .level == "off"' stop TOOLSY_STATE_enabled=true TOOLSY_STATE_until=$((now + 60))

# A new duration counts from now while on, and waits for the next start while off.
expect_nothing retime TOOLSY_STATE_duration=30
expect "(.until - $now | . >= 1800 and . <= 1805) and .enabled" retime TOOLSY_STATE_enabled=true TOOLSY_STATE_duration=30 TOOLSY_STATE_until=$((now + 60))
expect '.until == 0 and .status == "On"' retime TOOLSY_STATE_enabled=true TOOLSY_STATE_duration=0 TOOLSY_STATE_until=$((now + 60))

# Refresh and wake: report the time left, and switch off a hold whose end passed during sleep.
expect '.enabled == false and .status == "Off"' status TOOLSY_EVENT=refresh
expect ".enabled and .until == $((now + 299)) and .status == \"5 min left\"" status TOOLSY_EVENT=refresh TOOLSY_STATE_enabled=true TOOLSY_STATE_until=$((now + 299))
expect '.enabled and .status == "1 min left"' status TOOLSY_STATE_enabled=true TOOLSY_STATE_until=$((now + 2))
expect '.enabled and .status == "On"' status TOOLSY_STATE_enabled=true TOOLSY_STATE_until=0
expect '.enabled == false and .until == 0 and .status == "Off"' status TOOLSY_EVENT=wake TOOLSY_STATE_enabled=true TOOLSY_STATE_until=$((now - 1))

# Settings that are not what the manifest allows are refused with a message.
expect_failure start TOOLSY_STATE_duration="$odd"
expect_failure start TOOLSY_STATE_duration=-5
expect_failure start TOOLSY_STATE_duration=99999
expect_failure status TOOLSY_STATE_until='1; echo'
expect_failure status TOOLSY_STATE_display=maybe
expect_failure start TOOLSY_STATE_duration=x TOOLSY_LOCALE=ru
grep -q 'Длительность' "$data/err" || problem "a Russian error is expected, got: $(cat "$data/err")"
expect_failure hold PATH=/bin

# The service: an end that already passed switches the mod off without starting caffeinate.
start_service TOOLSY_STATE_enabled=true TOOLSY_STATE_until=$((now - 10))
if kill -0 "$service" 2>/dev/null || ! wait "$service"; then
    problem "hold with a past end: expected exit 0 at once"
else
    echo "ok   hold with a past end → exit 0"
fi

# A timed hold is caffeinate with the time left as its timeout; it exits 0 when that ends, which
# switches the mod off.
start_service TOOLSY_STATE_enabled=true TOOLSY_STATE_until=$((now + 3))
arguments=$(ps -o args= -p "$service" || true)
case $arguments in
'caffeinate -i -t '[123]) echo "ok   hold for 3 s → $arguments" ;;
*) problem "hold for 3 s: expected caffeinate -i -t N, got «$arguments»" ;;
esac
pmset -g assertions | grep -q "pid $service(caffeinate).*PreventUserIdleSystemSleep" ||
    problem "hold for 3 s: caffeinate holds no assertion"
started=$(date +%s)
if wait "$service"; then
    echo "ok   hold for 3 s → exit 0 after $(($(date +%s) - started)) s"
else
    problem "hold for 3 s: expected exit 0"
fi

# Without an end it holds until stopped; with the display setting it keeps the display awake too.
start_service TOOLSY_STATE_enabled=true TOOLSY_STATE_display=true TOOLSY_STATE_until=0
arguments=$(ps -o args= -p "$service" || true)
if [ "$arguments" = "caffeinate -di" ]; then
    echo "ok   hold without an end → $arguments"
else
    problem "hold without an end: expected caffeinate -di, got «$arguments»"
fi
kill "$service"
wait "$service" 2>/dev/null || true

if [ "$failures" -ne 0 ]; then
    echo "$failures check(s) failed" >&2
    exit 1
fi
echo "all checks passed"
