#!/bin/sh
# Commands started by the controls of the showcase page. $1 names the action.
set -eu
. "$(dirname "$0")/lib.sh"

value=${TOOLSY_VALUE-}

# require_count VALUE NAME: fails unless VALUE is a whole number of at most nine digits.
require_count() {
    case $1 in
    '' | *[!0-9]* | ??????????*) fail "$2: ожидается целое число, получено «$1»" ;;
    esac
}
case ${1-} in
greet)
    if [ -z "$value" ]; then
        echo '{"greeting": null}'
    else
        printf '{"greeting": %s}\n' "$(json_string "Привет, $value!")"
    fi
    ;;
count)
    clicks=${TOOLSY_STATE_clicks-0}
    require_count "$clicks" "Счётчик"
    require_count "$value" "Шаг счётчика"
    echo "{\"clicks\": $((clicks + value))}"
    ;;
reset)
    echo '{"clicks": 0}'
    ;;
dice)
    roll=$(od -An -N1 -tu1 /dev/urandom | tr -d ' ')
    echo "{\"dice\": $((roll % 6 + 1))}"
    ;;
live-echo)
    require_number "$value" 0 100 "Ползунок"
    printf '{"liveEcho": %s}\n' "$(json_string "Команда получила $value")"
    ;;
fail)
    echo "Намеренная ошибка: так Toolsy показывает сбой команды" >&2
    exit 3
    ;;
slow)
    sleep 3
    printf '{"slowResult": %s}\n' "$(json_string "Готово в $(date +%H:%M:%S)")"
    ;;
process-info)
    case $value in
    '' | *[!0-9]*) fail "Ожидается номер процесса, получено «${value}»" ;;
    esac
    info=$(LC_ALL=C ps -o user=,pcpu=,rss=,etime=,comm= -p "$value") || fail "Процесс $value уже завершился"
    printf '{"selectedProcess": %s}\n' "$(json_string "PID $value: $(printf '%s' "$info" | tr -s ' ')")"
    ;;
*)
    fail "Неизвестное действие «${1-}»"
    ;;
esac
