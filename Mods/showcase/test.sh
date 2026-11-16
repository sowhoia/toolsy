#!/bin/sh
# Runs every command of mod.json the way Toolsy does (same environment variables, mod folder as
# working directory) and a few seconds of the service, and checks that all output is valid.
set -eu
cd "$(dirname "$0")"
mod=$(pwd)
jq=/usr/bin/jq
data=$(mktemp -d)
services=
trap 'for pid in $services; do kill -TERM -- "-$pid" 2>/dev/null || true; done; rm -rf "$data"' EXIT
# Background jobs get process groups of their own, as Toolsy gives its services.
set -m
failures=0

problem() {
    printf 'FAIL %s\n' "$*" >&2
    failures=$((failures + 1))
}

# run COMMAND [VAR=VALUE…]: runs a command of mod.json with the settings as TOOLSY_STATE_*,
# overridden by the extra assignments. A command with "stdin" reads $data/in, which the caller
# writes. Leaves stdout, stderr and status in $data.
run() {
    name=$1
    shift
    definition=$($jq -c --arg name "$name" '.commands[$name]' mod.json)
    [ "$definition" != null ] || { problem "$name: not in mod.json"; return; }
    set -- $($jq -r '.settings | to_entries[] | "TOOLSY_STATE_\(.key)=\(.value)"' mod.json) TOOLSY_STATE_enabled=false "$@"
    set -- PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin HOME="$HOME" LANG=en_US.UTF-8 \
        TOOLSY_MOD_ID=showcase TOOLSY_MOD_DIR="$mod" TOOLSY_DATA_DIR="$data" TOOLSY_EVENT=command \
        TOOLSY_COMMAND="$name" "$@"
    program=$(printf '%s' "$definition" | $jq -r '.exec // empty')
    args=$(printf '%s' "$definition" | $jq -r '(.args // [])[]')
    input=/dev/null
    [ "$(printf '%s' "$definition" | $jq .stdin)" != true ] || input=$data/in
    status=0
    if [ -n "$program" ]; then
        # shellcheck disable=SC2086 # args in this manifest contain no spaces
        env -i "$@" "$mod/$program" $args >"$data/out" 2>"$data/err" <"$input" || status=$?
    else
        script=$(printf '%s' "$definition" | $jq -r '.shell')
        env -i "$@" /bin/sh -c "$script" toolsy $args >"$data/out" 2>"$data/err" <"$input" || status=$?
    fi
}

# expect_patch COMMAND [VAR=VALUE…]: the command succeeds and prints one JSON object or nothing.
expect_patch() {
    label="$*"
    run "$@"
    if [ "$status" -ne 0 ]; then
        problem "$label: exit $status: $(tail -n 1 "$data/err")"
    elif [ -s "$data/out" ] && ! $jq -e -s 'length == 1 and (.[0] | type) == "object"' "$data/out" >/dev/null 2>&1; then
        problem "$label: output is not one JSON object: $(cat "$data/out")"
    else
        printf 'ok   %s → %s\n' "$label" "$($jq -c . "$data/out" 2>/dev/null | cut -c 1-150)"
    fi
}

# expect_capture COMMAND [VAR=VALUE…]: the command succeeds and prints text for its capture key.
expect_capture() {
    label="$*"
    run "$@"
    if [ "$status" -ne 0 ]; then
        problem "$label: exit $status: $(tail -n 1 "$data/err")"
    elif [ -z "$(tr -d '[:space:]' <"$data/out")" ]; then
        problem "$label: nothing to capture"
    else
        printf 'ok   %s → %s\n' "$label" "$(head -c 150 "$data/out")"
    fi
}

# expect_failure COMMAND [VAR=VALUE…]: the command fails with a message, which Toolsy takes from
# the `error` of a JSON object on stdout or else from the last line of stderr.
expect_failure() {
    label="$*"
    run "$@"
    message=$($jq -r '.error // empty' "$data/out" 2>/dev/null || true)
    [ -n "$message" ] || message=$(grep -v '^[[:space:]]*$' "$data/err" | tail -n 1 || true)
    if [ "$status" -eq 0 ]; then
        problem "$label: expected a failure, got exit 0"
    elif [ -z "$message" ]; then
        problem "$label: failed without a message"
    else
        printf 'ok   %s → exit %s: %s\n' "$label" "$status" "$message"
    fi
}

# expect_service SECONDS JQ-CHECK [VAR=VALUE…]: every line the service prints in SECONDS is a JSON
# object satisfying JQ-CHECK, and there is about one line per second.
expect_service() {
    seconds=$1
    check=$2
    shift 2
    label="watch $*"
    run watch "$@" &
    runner=$!
    services="$services $runner"
    sleep "$seconds"
    # The runner leads a process group holding the service and everything it started; stop the
    # group like Toolsy does.
    kill -TERM -- "-$runner" 2>/dev/null || true
    wait "$runner" 2>/dev/null || true
    lines=$(grep -c '' "$data/out" || true)
    if [ "$lines" -lt $((seconds - 1)) ] || [ "$lines" -gt $((seconds + 1)) ]; then
        problem "$label: $lines lines in $seconds s: $(tail -n 1 "$data/err")"
    elif ! $jq -e -n "[inputs | (type == \"object\" and ($check))] | all" "$data/out" >/dev/null 2>&1; then
        problem "$label: invalid line in: $(cat "$data/out")"
    else
        printf 'ok   %s → %s lines, last %s\n' "$label" "$lines" "$(tail -n 1 "$data/out" | cut -c 1-120)"
    fi
}

odd=$(printf 'Ли "Ко" \\ \t\001 \377 🙂 $(x) `y`')

# check JQ-CHECK: the last output satisfies JQ-CHECK.
check() {
    $jq -e "$1" "$data/out" >/dev/null 2>&1 || problem "expected $1, got $(cat "$data/out")"
}

expect_patch refresh
check '(.interfaces | type) == "array" and (.processes[0].subtitle | test("^PID [0-9]+ · [0-9]+ MB$")) and .bootTime > 0'
pid=$($jq -r '.processes[0].id' "$data/out")
interface=$($jq -r '.interfaces[0] // empty' "$data/out")
expect_patch process-info TOOLSY_VALUE="$pid"
expect_patch refresh TOOLSY_STATE_order=Memory TOOLSY_LOCALE=ru-ru
check '.processes[0].subtitle | test("МБ$")'
expect_patch refresh TOOLSY_EVENT=refresh
expect_patch greet TOOLSY_KEY=greetingName TOOLSY_VALUE="$odd"
grep -q 'Ли' "$data/out" || problem "greet: name missing from $(cat "$data/out")"
expect_patch greet TOOLSY_KEY=greetingName TOOLSY_VALUE=Toolsy TOOLSY_LOCALE=ru
check '.greeting == "Привет, Toolsy!"'
expect_patch greet TOOLSY_KEY=greetingName TOOLSY_VALUE=
expect_patch count TOOLSY_VALUE=1
expect_patch count TOOLSY_VALUE=1 TOOLSY_STATE_clicks=41
check '.clicks == 42'
expect_patch reset
expect_patch dice
check '.dice >= 1 and .dice <= 6'
expect_patch live-echo TOOLSY_KEY=liveLevel TOOLSY_VALUE=42.5
expect_patch process-info TOOLSY_VALUE=$$
expect_capture os-version

# The main switch's hooks are shell commands.
expect_patch on TOOLSY_EVENT=enable
check '.onSince > 0'
expect_patch off TOOLSY_EVENT=disable
check '.onSince == null'

# A command with "stdin" reads the command input as JSON.
printf '%s' '{"event": "command", "command": "input", "locale": "ru", "state": {"enabled": true, "clicks": 3}}' >"$data/in"
expect_patch input
check '.inputKeys == 2 and .inputEvent == "command" and .inputLocale == "ru"'
printf '%s' '{"event": "command", "command": "input", "state": {}}' >"$data/in"
expect_patch input
check '.inputKeys == 0 and .inputLocale == "none"'

# The picker fed from state: its options are the interfaces refresh reported.
if [ -n "$interface" ]; then
    expect_patch interface-info TOOLSY_KEY=interface TOOLSY_VALUE="$interface"
    check '(.interfaceIn | type) == "number" and (.interfaceOut | type) == "number"'
else
    problem "refresh reported no network interface"
fi

# Notifications, as text and with a title.
expect_patch notify TOOLSY_VALUE=text
check '.notify == "Hello from the showcase"'
expect_patch notify TOOLSY_VALUE=titled TOOLSY_STATE_clicks=7 TOOLSY_LOCALE=ru
check '.notify == {"title": "Витрина", "body": "Нажатий кнопки: 7"}'

# System events, counted.
for event in launch wake network power; do
    expect_patch event TOOLSY_EVENT=$event TOOLSY_STATE_eventCount=4
    check '.eventCount == 5 and .lastEventAt > 0 and (.lastEvent | type) == "string"'
done
expect_patch event TOOLSY_EVENT=wake TOOLSY_LOCALE=ru
check '.eventCount == 1 and .lastEvent == "Mac вышел из сна"'

started=$(date +%s)
expect_patch slow
[ $(($(date +%s) - started)) -ge 3 ] || problem "slow: finished in under 3 s"

expect_failure fail
expect_failure fail TOOLSY_LOCALE=ru
grep -q 'Намеренная ошибка' "$data/out" || problem "fail: a Russian error is expected, got $(cat "$data/out")"
expect_failure count TOOLSY_VALUE=1 TOOLSY_STATE_clicks="$odd"
expect_failure count TOOLSY_VALUE=1.5
expect_failure live-echo TOOLSY_VALUE="$odd"
expect_failure process-info TOOLSY_VALUE="1; echo"
expect_failure process-info TOOLSY_VALUE=999999
expect_failure refresh TOOLSY_STATE_order="$odd"
expect_failure interface-info TOOLSY_VALUE="$odd"
expect_failure interface-info TOOLSY_VALUE=en999
expect_failure notify TOOLSY_VALUE="$odd"
expect_failure event TOOLSY_EVENT=command
expect_failure event TOOLSY_EVENT=wake TOOLSY_STATE_eventCount="$odd"
expect_failure watch TOOLSY_STATE_amplitude="$odd"
expect_failure watch TOOLSY_STATE_period=1
expect_failure watch TOOLSY_STATE_waveShape="$odd"
expect_failure watch TOOLSY_STATE_showSecond=1

expect_service 4 '(.wave | type) == "number" and (.wave2 | type) == "number" and .load1 >= 0 and .level == .loadLevel'
expect_service 3 '.wave2 == null and (.wave | fabs) == 30' TOOLSY_STATE_showSecond=false TOOLSY_STATE_waveShape=square TOOLSY_STATE_amplitude=30
expect_service 3 '(.wave | fabs) <= 100' TOOLSY_STATE_waveShape=triangle TOOLSY_STATE_amplitude=100 TOOLSY_STATE_period=5
expect_service 2 '.status | startswith("Нагрузка ")' TOOLSY_LOCALE=ru

if [ "$failures" -ne 0 ]; then
    echo "$failures check(s) failed" >&2
    exit 1
fi
echo "all checks passed"
