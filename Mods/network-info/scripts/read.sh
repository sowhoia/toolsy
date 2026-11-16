#!/bin/sh
# Reads what the network looks like right now and prints it as one patch. Everything comes from
# this Mac: the System Configuration store (scutil), the interface (ifconfig) and, for Wi-Fi,
# system_profiler. Nothing is sent anywhere.
#
# The shell only collects text; patch.jq turns it into JSON with jq, which escapes whatever it is
# given, so a network service the user named `Desk "LAN"` cannot break the patch.
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

# show KEY: the dictionary the System Configuration store holds under KEY; nothing when it has none.
show() {
    printf 'show %s\n' "$1" | scutil | grep -v '^ *No such key$' || true
}

# field NAME: the value of NAME in the dictionary on standard input.
field() {
    awk -v name="$1" '$1 == name && $2 == ":" { sub(/^[^:]*: /, ""); print; exit }'
}

# items NAME: the elements of the array NAME in the dictionary on standard input, one per line.
items() {
    awk -v name="$1" '
        $1 == name && $3 == "<array>" { inside = 1; next }
        inside && /^ *}/ { exit }
        inside { sub(/^[^:]*: /, ""); print }'
}

interface= service= kind= hardware= method= router= router6= servers= domains=
ipv4= mask= ipv6= linklocal= mac= mtu= report=null problem=

global4=$(show State:/Network/Global/IPv4)
global6=$(show State:/Network/Global/IPv6)
interface=$(printf '%s\n' "$global4" | field PrimaryInterface)
service=$(printf '%s\n' "$global4" | field PrimaryService)
if [ -z "$interface" ]; then
    # An IPv6-only network has no IPv4 primary.
    interface=$(printf '%s\n' "$global6" | field PrimaryInterface)
    service=$(printf '%s\n' "$global6" | field PrimaryService)
fi

if [ -n "$interface" ]; then
    # Both go into further queries; anything else is not what the store holds.
    case $interface in *[!a-z0-9]*) fail "$(say "Unexpected interface name" "Неожиданное имя интерфейса") «${interface}»" ;; esac
    case $service in *[!A-Za-z0-9-]*) fail "$(say "Unexpected network service" "Неожиданная сетевая служба") «${service}»" ;; esac

    router=$(printf '%s\n' "$global4" | field Router)
    router6=$(printf '%s\n' "$global6" | field Router)
    dns=$(show State:/Network/Global/DNS)
    servers=$(printf '%s\n' "$dns" | items ServerAddresses)
    domains=$(printf '%s\n' "$dns" | items SearchDomains)

    # The service as System Settings names it ("Wi-Fi", "USB 10/100/1000 LAN") and its hardware.
    # A VPN that is the primary service may have no interface entry.
    if [ -n "$service" ]; then
        setup=$(show "Setup:/Network/Service/$service/Interface")
        hardware=$(printf '%s\n' "$setup" | field Hardware)
        kind=$(printf '%s\n' "$setup" | field UserDefinedName)
        method=$(show "Setup:/Network/Service/$service/IPv4" | field ConfigMethod)
    fi
    if [ -z "$kind" ]; then
        case $interface in
        utun* | ipsec* | ppp*) kind=VPN ;;
        *) kind=$interface ;;
        esac
    fi
    case $method in
    Manual) method=$(say "Manually" "Вручную") ;;
    INFORM) method=$(say "DHCP with a manual address" "DHCP с ручным адресом") ;;
    LinkLocal) method=$(say "Link-local only" "Только локальный адрес") ;;
    esac

    addresses=$(ifconfig "$interface") || fail "$(say "Cannot read the interface" "Не удалось прочитать интерфейс") $interface"
    ipv4=$(printf '%s\n' "$addresses" | awk '$1 == "inet" { print $2; exit }')
    # "netmask 0xffffff00" → 255.255.255.0
    mask=$(printf '%s\n' "$addresses" | awk '$1 == "inet" { for (i = 3; i < NF; i++) if ($i == "netmask") print $(i + 1); exit }')
    case $mask in
    0x[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f])
        bits=$((mask))
        mask=$((bits >> 24 & 255)).$((bits >> 16 & 255)).$((bits >> 8 & 255)).$((bits & 255))
        ;;
    *) mask= ;;
    esac
    # One line per global IPv6 address with its kind. Deprecated addresses are no longer used for
    # new connections and are left out.
    ipv6=$(printf '%s\n' "$addresses" | awk '
        $1 != "inet6" || $2 ~ /^fe80:/ || / deprecated/ { next }
        { print $2, (/ temporary/ ? "temporary" : (/ autoconf/ ? "stable" : "assigned")) }')
    linklocal=$(printf '%s\n' "$addresses" | awk '$1 == "inet6" && $2 ~ /^fe80:/ { sub(/%.*/, "", $2); print $2; exit }')
    mac=$(printf '%s\n' "$addresses" | awk '$1 == "ether" { print $2; exit }')
    mtu=$(printf '%s\n' "$addresses" | awk 'NR == 1 { for (i = 2; i < NF; i++) if ($i == "mtu") print $(i + 1); exit }')

    # Without the location permission macOS redacts the Wi-Fi network's name and the access point's
    # address; the rest of the report is readable.
    if [ "$hardware" = AirPort ]; then
        report=$(system_profiler -detailLevel basic SPAirPortDataType -json 2>/dev/null) || {
            report=null
            problem=$(say "Wi-Fi details could not be read: system_profiler failed." "Не удалось прочитать данные Wi-Fi: system_profiler завершился с ошибкой.")
        }
    fi
fi

printf '%s' "$report" | jq -c -f "${0%/*}/patch.jq" \
    --arg interface "$interface" --arg kind "$kind" --arg ipv4 "$ipv4" --arg mask "$mask" \
    --arg router "$router" --arg router6 "$router6" --arg ipv6 "$ipv6" --arg linkLocal "$linklocal" \
    --arg servers "$servers" --arg domains "$domains" --arg method "$method" --arg mac "$mac" \
    --arg mtu "$mtu" --arg wifiProblem "$problem" \
    --arg offline "$(say "Not connected" "Нет подключения")" --arg offlineShort "$(say "Offline" "Нет сети")" \
    --arg none "$(say "None" "Нет")" \
    --arg temporary "$(say "Temporary" "Временный")" --arg stable "$(say "Stable" "Постоянный")" \
    --arg assigned "$(say "Assigned" "Назначенный")"
