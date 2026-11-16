#!/bin/sh
# Refresh: the computer's name and uptime, and the top processes for the list and the bar chart.
set -eu
. "$(dirname "$0")/lib.sh"

case ${TOOLSY_STATE_sortBy-} in
CPU) order=-r ;;
Память) order=-m ;;
*) fail "Неизвестный порядок сортировки «${TOOLSY_STATE_sortBy-}»" ;;
esac
name=$(scutil --get ComputerName)
name=$(printf '%s' "$name" | utf8)
boot=$(sysctl -n kern.boottime | sed -n 's/^{ sec = \([0-9]*\),.*/\1/p')
now=$(date +%s)
[ -n "$boot" ] || fail "Не удалось прочитать время загрузки"

LC_ALL=C ps -Aceo pid=,pcpu=,rss=,comm= "$order" | utf8 | LC_ALL=C awk "$JSON_AWK"'
    BEGIN { json_init(); name = ARGV[1]; uptime = ARGV[3] - ARGV[2]; ARGC = 1 }
    NR <= 8 {
        command = $0
        sub(/^ *[0-9]+ +[0-9.]+ +[0-9]+ +/, "", command)
        rows = rows (NR > 1 ? ", " : "") sprintf("{\"id\": %s, \"title\": %s, \"subtitle\": %s, \"value\": %s, \"icon\": \"gearshape\"}",
            json($1), json(command), json(sprintf("PID %d · %.0f МБ", $1, $3 / 1024)), json(sprintf("%.1f%%", $2)))
        cpu = cpu (NR > 1 ? ", " : "") sprintf("%.1f", $2)
    }
    END {
        printf "{\"hostname\": %s, \"uptime\": %d, \"processCount\": %d, \"processes\": [%s], \"topCPU\": [%s]}\n",
            json(name), uptime, NR, rows, cpu
    }' "$name" "$boot" "$now"
