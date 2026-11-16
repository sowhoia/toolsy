#!/bin/sh
# The showcase service: prints one JSON patch per second while the mod is on. Toolsy restarts
# it whenever a setting changes, so the settings are read once at start.
set -eu
. "$(dirname "$0")/lib.sh"

amplitude=${TOOLSY_STATE_amplitude-}
period=${TOOLSY_STATE_period-}
shape=${TOOLSY_STATE_waveShape-}
second=${TOOLSY_STATE_showSecond-}
require_number "$amplitude" 0 100 "$(say "Amplitude" "Амплитуда")"
require_number "$period" 2 120 "$(say "Period" "Период")"
case $shape in
sine | triangle | square) ;;
*) fail "$(say "Unknown wave shape" "Неизвестная форма волны") «${shape}»" ;;
esac
case $second in
true | false) ;;
*) fail "$(say "Second wave: expected true or false, got" "Вторая волна: ожидается true или false, получено") «${second}»" ;;
esac
cpus=$(sysctl -n hw.ncpu)
memory=$(sysctl -n hw.memsize)

# The loop only collects readings; one long-lived awk keeps the state between seconds and prints
# a patch at every tick. That keeps it to three short processes per second.
while :; do
    sysctl -n vm.loadavg kern.memorystatus_level
    netstat -ib
    echo tick
    sleep 1
done | LC_ALL=C awk "$JSON_AWK"'
    BEGIN {
        amplitude = ARGV[1]; period = ARGV[2]; shape = ARGV[3]; second = ARGV[4]
        json_init()
        cpus = ARGV[5]; memory = ARGV[6]; loadWord = ARGV[7]; memoryWord = ARGV[8]; stopped = ARGV[9]
        ARGC = 1
        pi = atan2(0, -1)
        t = 0
    }
    function wave(phase, a,   p) {
        if (shape == "sine") return a * sin(phase)
        if (shape == "square") return sin(phase) >= 0 ? a : -a
        p = phase / (2 * pi); p -= int(p)
        return a * (1 - 4 * (p < 0.5 ? 0.5 - p : p - 0.5))
    }
    # sysctl prints "{ 1.23 1.45 1.67 }", then the percentage of memory that is available.
    /^\{ / { split($0, average, /[{} ]+/); load1 = average[2]; load5 = average[3]; load15 = average[4]; next }
    /^[0-9]+$/ { free = $1; next }
    # Physical interfaces only; tunnels would count VPN traffic twice. Counters are the 5th and
    # 2nd column from the end because the address column can be empty.
    $1 ~ /^en[0-9]+$/ && $3 ~ /^<Link#/ { rx += $(NF - 4); tx += $(NF - 1); next }
    $0 == "tick" {
        loadPercent = 100 * load1 / cpus; if (loadPercent > 100) loadPercent = 100
        level = load1 < 0.7 * cpus ? "ok" : (load1 < cpus ? "warn" : "error")
        phase = 2 * pi * t / period
        printf "{\"wave\": %.2f, \"wave2\": ", wave(phase, amplitude)
        if (second == "true") printf "%.2f", wave(phase + pi / 2, amplitude / 2); else printf "null"
        printf ", \"load1\": %.2f, \"load5\": %.2f, \"load15\": %.2f", load1, load5, load15
        printf ", \"loadPercent\": %.1f, \"loadLevel\": \"%s\"", loadPercent, level
        printf ", \"memoryUsed\": %d, \"availableBytes\": %.0f", 100 - free, memory * free / 100
        if (t > 0) printf ", \"rxRate\": %.0f, \"txRate\": %.0f", rx - previousRx, tx - previousTx
        printf ", \"status\": %s, \"level\": \"%s\"}\n", json(sprintf("%s %.2f · %s %d%%", loadWord, load1, memoryWord, 100 - free)), level
        fflush()
        previousRx = rx; previousTx = tx; rx = 0; tx = 0
        t++
    }
    # The loop runs until the service is stopped, so running out of input means it failed.
    END {
        print stopped > "/dev/stderr"
        exit 1
    }' "$amplitude" "$period" "$shape" "$second" "$cpus" "$memory" \
    "$(say Load Нагрузка)" "$(say memory память)" "$(say "Collecting readings stopped" "Сбор данных остановился")"
