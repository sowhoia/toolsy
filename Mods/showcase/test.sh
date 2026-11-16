#!/bin/sh
# Runs every command of mod.json the way Toolsy does (same environment variables, mod folder as
# working directory) and a few seconds of the service, and checks that all output is valid.
set -eu
cd "$(dirname "$0")"
mod=$(pwd)
jq=/usr/bin/jq
data=$(mktemp -d)
trap 'rm -rf "$data"' EXIT
failures=0

problem() {
    printf 'FAIL %s\n' "$*" >&2
    failures=$((failures + 1))
}

# run COMMAND [VAR=VALUE…]: runs a command of mod.json with the settings as TOOLSY_STATE_*,
# overridden by the extra assignments. Leaves stdout, stderr and status in $data.
run() {
    name=$1
    shift
    definition=$($jq -c --arg name "$name" '.commands[$name]' mod.json)
    [ "$definition" != null ] || { problem "$name: not in mod.json"; return; }
    set -- $($jq -r '.settings | to_entries[] | "TOOLSY_STATE_\(.key)=\(.value)"' mod.json) "$@"
    set -- PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin HOME="$HOME" LANG=en_US.UTF-8 \
        TOOLSY_MOD_ID=showcase TOOLSY_MOD_DIR="$mod" TOOLSY_DATA_DIR="$data" TOOLSY_EVENT=command \
        TOOLSY_COMMAND="$name" "$@"
    program=$(printf '%s' "$definition" | $jq -r '.exec // empty')
    args=$(printf '%s' "$definition" | $jq -r '(.args // [])[]')
    status=0
    if [ -n "$program" ]; then
        # shellcheck disable=SC2086 # args in this manifest contain no spaces
        env -i "$@" "$mod/$program" $args >"$data/out" 2>"$data/err" </dev/null || status=$?
    else
        script=$(printf '%s' "$definition" | $jq -r '.shell')
        env -i "$@" /bin/sh -c "$script" toolsy $args >"$data/out" 2>"$data/err" </dev/null || status=$?
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

# expect_service SECONDS JQ-CHECK [VAR=VALUE…]: every line the service prints in SECONDS is a JSON
# object satisfying JQ-CHECK, and there is about one line per second.
expect_service() {
    seconds=$1
    check=$2
    shift 2
    label="watch $*"
    # Stopping the service makes the shell report "Terminated"; that is expected.
    run watch "$@" 2>/dev/null &
    runner=$!
    sleep "$seconds"
    # The service is the runner's child; stop it like Toolsy does, then the runner returns.
    pkill -TERM -f "$mod/scripts/service.sh" || true
    wait "$runner" || true
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

expect_patch refresh
pid=$($jq -r '.processes[0].id' "$data/out")
expect_patch process-info TOOLSY_VALUE="$pid"
expect_patch refresh TOOLSY_STATE_sortBy=Память
expect_patch refresh TOOLSY_EVENT=refresh
expect_patch greet TOOLSY_KEY=greetingName TOOLSY_VALUE="$odd"
grep -q 'Ли' "$data/out" || problem "greet: name missing from $(cat "$data/out")"
expect_patch greet TOOLSY_KEY=greetingName TOOLSY_VALUE=
expect_patch count TOOLSY_VALUE=1
expect_patch count TOOLSY_VALUE=1 TOOLSY_STATE_clicks=41
$jq -e '.clicks == 42' "$data/out" >/dev/null || problem "count: expected 42, got $(cat "$data/out")"
expect_patch reset
expect_patch dice
$jq -e '.dice >= 1 and .dice <= 6' "$data/out" >/dev/null || problem "dice: $(cat "$data/out")"
expect_patch live-echo TOOLSY_KEY=liveLevel TOOLSY_VALUE=42.5
expect_patch process-info TOOLSY_VALUE=$$
expect_capture os-version

started=$(date +%s)
expect_patch slow
[ $(($(date +%s) - started)) -ge 3 ] || problem "slow: finished in under 3 s"

expect_failure fail
expect_failure count TOOLSY_VALUE=1 TOOLSY_STATE_clicks="$odd"
expect_failure count TOOLSY_VALUE=1.5
expect_failure live-echo TOOLSY_VALUE="$odd"
expect_failure process-info TOOLSY_VALUE="1; echo"
expect_failure process-info TOOLSY_VALUE=999999
expect_failure refresh TOOLSY_STATE_sortBy="$odd"
expect_failure watch TOOLSY_STATE_amplitude="$odd"
expect_failure watch TOOLSY_STATE_period=1
expect_failure watch TOOLSY_STATE_waveShape="$odd"
expect_failure watch TOOLSY_STATE_showSecond=1

expect_service 4 '(.wave | type) == "number" and (.wave2 | type) == "number" and .load1 >= 0 and .level == .loadLevel'
expect_service 3 '.wave2 == null and (.wave | fabs) == 30' TOOLSY_STATE_showSecond=false TOOLSY_STATE_waveShape=square TOOLSY_STATE_amplitude=30
expect_service 3 '(.wave | fabs) <= 100' TOOLSY_STATE_waveShape=triangle TOOLSY_STATE_amplitude=100 TOOLSY_STATE_period=5

if [ "$failures" -ne 0 ]; then
    echo "$failures check(s) failed" >&2
    exit 1
fi
echo "all checks passed"
