#!/bin/sh
# Refresh: the computer's name, boot time and uptime, the network interfaces for the picker fed from
# state, and the top processes for the list and the bar chart.
set -eu
. "$(dirname "$0")/lib.sh"

case ${TOOLSY_STATE_order-} in
CPU) order=-r ;;
Memory) order=-m ;;
*) fail "$(say "Unknown sort order" "Неизвестный порядок сортировки") «${TOOLSY_STATE_order-}»" ;;
esac
name=$(scutil --get ComputerName)
name=$(printf '%s' "$name" | utf8)
boot=$(sysctl -n kern.boottime | sed -n 's/^{ sec = \([0-9]*\),.*/\1/p')
now=$(date +%s)
[ -n "$boot" ] || fail "$(say "Could not read the boot time" "Не удалось прочитать время загрузки")"
# Interfaces that are up and count traffic; netstat marks those that are down with "*".
interfaces=$(netstat -ibn | awk '$3 ~ /^<Link#/ && $1 !~ /\*$/ && !seen[$1]++ { print $1 }')

LC_ALL=C ps -Aceo pid=,pcpu=,rss=,comm= "$order" | utf8 | LC_ALL=C awk "$JSON_AWK"'
    BEGIN {
        json_init(); name = ARGV[1]; boot = ARGV[2]; uptime = ARGV[3] - ARGV[2]; megabytes = ARGV[5]
        count = split(ARGV[4], names, "\n")
        for (i = 1; i <= count; i++) interfaces = interfaces (i > 1 ? ", " : "") json(names[i])
        ARGC = 1
    }
    NR <= 8 {
        command = $0
        sub(/^ *[0-9]+ +[0-9.]+ +[0-9]+ +/, "", command)
        rows = rows (NR > 1 ? ", " : "") sprintf("{\"id\": %s, \"title\": %s, \"subtitle\": %s, \"value\": %s, \"icon\": \"gearshape\"}",
            json($1), json(command), json(sprintf("PID %d · %.0f %s", $1, $3 / 1024, megabytes)), json(sprintf("%.1f%%", $2)))
        cpu = cpu (NR > 1 ? ", " : "") sprintf("%.1f", $2)
    }
    END {
        printf "{\"hostname\": %s, \"bootTime\": %d, \"uptime\": %d, \"processCount\": %d, \"processes\": [%s], \"topCPU\": [%s], \"interfaces\": [%s]}\n",
            json(name), boot, uptime, NR, rows, cpu, interfaces
    }' "$name" "$boot" "$now" "$interfaces" "$(say MB МБ)"
