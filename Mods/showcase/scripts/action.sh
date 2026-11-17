#!/bin/sh
# Commands started by the controls of the showcase page and by system events. $1 names the action.
set -eu
# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$(dirname "$0")/lib.sh"

value=${TOOLSY_VALUE-}

case ${1-} in
greet)
    if [ -z "$value" ]; then
        echo '{"greeting": null}'
    else
        printf '{"greeting": %s}\n' "$(json_string "$(say "Hello, $value!" "Привет, $value!")")"
    fi
    ;;
count)
    clicks=${TOOLSY_STATE_clicks-0}
    require_count "$clicks" "$(say "Counter" "Счётчик")"
    require_count "$value" "$(say "Counter step" "Шаг счётчика")"
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
    require_number "$value" 0 100 "$(say "Slider" "Ползунок")"
    printf '{"liveEcho": %s}\n' "$(json_string "$(say "The command received $value" "Команда получила $value")")"
    ;;
fail)
    # A failing command may explain itself with a JSON `error` on standard output; without one,
    # Toolsy shows the last line of standard error.
    printf '{"error": %s}\n' "$(json_string "$(say "A deliberate failure: this is how Toolsy shows a command that failed" "Намеренная ошибка: так Toolsy показывает сбой команды")")"
    exit 3
    ;;
slow)
    sleep 3
    printf '{"slowResult": %s}\n' "$(json_string "$(say "Done at" "Готово в") $(date +%H:%M:%S)")"
    ;;
process-info)
    case $value in
    '' | *[!0-9]*) fail "$(say "Expected a process number, got" "Ожидается номер процесса, получено") «${value}»" ;;
    esac
    info=$(LC_ALL=C ps -o user=,pcpu=,rss=,etime=,comm= -p "$value") || fail "$(say "Process $value has already exited" "Процесс $value уже завершился")"
    printf '{"selectedProcess": %s}\n' "$(json_string "PID $value: $(printf '%s' "$info" | tr -s ' ')")"
    ;;
interface-info)
    # The picker's options come from `interfaces`, which refresh fills; the value is still checked.
    case $value in
    '' | *[!a-z0-9]*) fail "$(say "Expected an interface name, got" "Ожидается имя интерфейса, получено") «${value}»" ;;
    esac
    netstat -ibn | awk -v name="$value" '
        $1 == name && $3 ~ /^<Link#/ { printf "{\"interfaceIn\": %s, \"interfaceOut\": %s}\n", $(NF - 4), $(NF - 1); found = 1; exit }
        END { if (!found) exit 1 }' || fail "$(say "Interface $value is gone" "Интерфейса $value больше нет")"
    ;;
notify)
    # A notification is a string, or an object with a title and a body.
    case $value in
    text) printf '{"notify": %s}\n' "$(json_string "$(say "Hello from the showcase" "Привет от витрины")")" ;;
    titled)
        clicks=${TOOLSY_STATE_clicks-0}
        require_count "$clicks" "$(say "Counter" "Счётчик")"
        printf '{"notify": {"title": %s, "body": %s}}\n' "$(json_string "$(say "Showcase" "Витрина")")" \
            "$(json_string "$(say "Buttons pressed so far: $clicks" "Нажатий кнопки: $clicks")")"
        ;;
    *) fail "$(say "Unknown kind of notification" "Неизвестный вид уведомления") «${value}»" ;;
    esac
    ;;
event)
    # Runs on the system events of the manifest while the mod is on; TOOLSY_EVENT names the event.
    case ${TOOLSY_EVENT-} in
    launch) name=$(say "Toolsy started" "Toolsy запущен") ;;
    wake) name=$(say "The Mac woke from sleep" "Mac вышел из сна") ;;
    network) name=$(say "The network changed" "Сеть изменилась") ;;
    power) name=$(say "The power source changed" "Сменился источник питания") ;;
    *) fail "$(say "Unknown event" "Неизвестное событие") «${TOOLSY_EVENT-}»" ;;
    esac
    count=${TOOLSY_STATE_eventCount-0}
    require_count "$count" "$(say "Events" "События")"
    printf '{"lastEvent": %s, "lastEventAt": %s, "eventCount": %s}\n' "$(json_string "$name")" "$(date +%s)" $((count + 1))
    ;;
*)
    fail "$(say "Unknown action" "Неизвестное действие") «${1-}»"
    ;;
esac
