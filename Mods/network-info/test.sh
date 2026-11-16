#!/bin/sh
# Runs the command of mod.json the way Toolsy does (same environment variables, mod folder as
# working directory) and checks the patches. scutil, ifconfig and system_profiler are replaced by
# stubs that print fixtures with documentation addresses, so every kind of network can be tested;
# one last run reads this Mac and checks only the shape of the patch, without printing it.
set -eu
cd "$(dirname "$0")"
mod=$(pwd)
jq=/usr/bin/jq
id=$($jq -r .id mod.json)
data=$(mktemp -d)
trap 'rm -rf "$data"' EXIT
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

# The stubs. scutil answers `show KEY` from the file named after KEY; ifconfig prints
# ifconfig-<interface>; system_profiler prints profile.json. A missing file is a missing key, an
# interface that does not exist, or a failure.
stubs=$data/stubs
mkdir -p "$stubs"
cat >"$stubs/scutil" <<'STUB'
#!/bin/sh
read -r verb key
file="$FIXTURES/$(printf '%s' "$key" | tr '/:' '__')"
if [ "$verb" = show ] && [ -f "$file" ]; then cat "$file"; else echo "  No such key"; fi
STUB
cat >"$stubs/ifconfig" <<'STUB'
#!/bin/sh
cat "$FIXTURES/ifconfig-$1" 2>/dev/null || { echo "ifconfig: interface $1 does not exist" >&2; exit 1; }
STUB
cat >"$stubs/system_profiler" <<'STUB'
#!/bin/sh
cat "$FIXTURES/profile.json" 2>/dev/null || { echo "system_profiler: no data" >&2; exit 1; }
STUB
chmod +x "$stubs/scutil" "$stubs/ifconfig" "$stubs/system_profiler"
stubbed="PATH=$stubs:/usr/bin:/bin:/usr/sbin:/sbin"

# fixture NAME KEY: writes standard input as what scutil shows for KEY in the fixture NAME.
fixture() {
    mkdir -p "$data/$1"
    cat >"$data/$1/$(printf '%s' "$2" | tr '/:' '__')"
}

# Wi-Fi with IPv4 and IPv6: a temporary, a stable and a deprecated address, in that order.
service=0A1B2C3D-0000-4000-8000-000000000001
fixture wifi State:/Network/Global/IPv4 <<FIXTURE
<dictionary> {
  PrimaryInterface : en0
  PrimaryService : $service
  Router : 192.0.2.1
}
FIXTURE
fixture wifi State:/Network/Global/IPv6 <<FIXTURE
<dictionary> {
  PrimaryInterface : en0
  PrimaryService : $service
  Router : fe80::1
}
FIXTURE
fixture wifi State:/Network/Global/DNS <<'FIXTURE'
<dictionary> {
  SearchDomains : <array> {
    0 : example.com
  }
  ServerAddresses : <array> {
    0 : 192.0.2.53
    1 : 2001:db8::53
  }
}
FIXTURE
fixture wifi "Setup:/Network/Service/$service/Interface" <<'FIXTURE'
<dictionary> {
  DeviceName : en0
  Hardware : AirPort
  Type : Ethernet
  UserDefinedName : Wi-Fi
}
FIXTURE
fixture wifi "Setup:/Network/Service/$service/IPv4" <<'FIXTURE'
<dictionary> {
  ConfigMethod : DHCP
}
FIXTURE
cat >"$data/wifi/ifconfig-en0" <<'FIXTURE'
en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
	options=6460<TSO4,TSO6,CHANNEL_IO,PARTIAL_CSUM,ZEROINVERT_CSUM>
	ether 00:00:5e:00:53:01
	inet6 fe80::1%en0 prefixlen 64 secured scopeid 0xb
	inet 192.0.2.10 netmask 0xffffff00 broadcast 192.0.2.255
	inet6 2001:db8::20 prefixlen 64 autoconf temporary
	inet6 2001:db8::10 prefixlen 64 autoconf secured
	inet6 2001:db8::30 prefixlen 64 deprecated autoconf temporary
	nd6 options=201<PERFORMNUD,DAD>
	media: autoselect
	status: active
FIXTURE
profile() {
    cat <<FIXTURE
{"SPAirPortDataType": [{"spairport_airport_interfaces": [
  {"_name": "awdl0", "spairport_current_network_information": {"spairport_network_type": "spairport_network_type_station"}},
  {"_name": "en0", "spairport_current_network_information": {
    "_name": "<redacted>", "spairport_network_channel": "$1", "spairport_network_country_code": "US",
    "spairport_network_mcs": 11, "spairport_network_phymode": "802.11ax", "spairport_network_rate": 1200,
    "spairport_network_type": "spairport_network_type_station", "spairport_security_mode": "$2",
    "spairport_signal_noise": "$3"}}]}]}
FIXTURE
}
profile "36 (5GHz, 80MHz)" spairport_security_mode_wpa3_personal "-58 dBm / -92 dBm" >"$data/wifi/profile.json"

# The same network with a weak signal on an open 2.4 GHz network.
cp -R "$data/wifi" "$data/weak"
profile "6 (2GHz, 20MHz)" spairport_security_mode_none "-75 dBm / -90 dBm" >"$data/weak/profile.json"

# The same network when system_profiler fails.
cp -R "$data/wifi" "$data/no-profile"
rm "$data/no-profile/profile.json"

# A service named with quotes, a backslash and an emoji, on Ethernet with IPv6 only, set up manually.
fixture ipv6 State:/Network/Global/IPv6 <<FIXTURE
<dictionary> {
  PrimaryInterface : en7
  PrimaryService : $service
}
FIXTURE
fixture ipv6 "Setup:/Network/Service/$service/Interface" <<'FIXTURE'
<dictionary> {
  DeviceName : en7
  Hardware : Ethernet
  UserDefinedName : Desk "LAN" \ 🙂
}
FIXTURE
fixture ipv6 "Setup:/Network/Service/$service/IPv4" <<'FIXTURE'
<dictionary> {
  ConfigMethod : Manual
}
FIXTURE
cat >"$data/ipv6/ifconfig-en7" <<'FIXTURE'
en7: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 9000
	ether 00:00:5e:00:53:07
	inet6 2001:db8::7 prefixlen 64
	status: active
FIXTURE

# A VPN as the primary service, without an interface entry.
fixture vpn State:/Network/Global/IPv4 <<FIXTURE
<dictionary> {
  PrimaryInterface : utun4
  PrimaryService : $service
  Router : 192.0.2.66
}
FIXTURE
cat >"$data/vpn/ifconfig-utun4" <<'FIXTURE'
utun4: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1380
	inet 192.0.2.66 --> 192.0.2.66 netmask 0xffffffff
FIXTURE

# The interface disappears between the two reads.
mkdir -p "$data/vanished"
cp "$data/wifi/State__Network_Global_IPv4" "$data/vanished/"

# A store that names an interface no tool should be handed.
fixture strange State:/Network/Global/IPv4 <<'FIXTURE'
<dictionary> {
  PrimaryInterface : en0;reboot
}
FIXTURE
mkdir -p "$data/offline"

on() {
    printf '%s\n' "$stubbed" "FIXTURES=$data/$1"
}

expect '.interface == "en0" and .kind == "Wi-Fi" and .address == "192.0.2.10" and .ipv4 == "192.0.2.10"
    and .mask == "255.255.255.0" and .router == "192.0.2.1" and .router6 == "fe80::1"
    and .ipv6 == "2001:db8::10" and .ipv6All == [{"title": "2001:db8::20", "subtitle": "Temporary"}, {"title": "2001:db8::10", "subtitle": "Stable"}]
    and .linkLocal == "fe80::1" and .dns == ["192.0.2.53", "2001:db8::53"] and .searchDomains == ["example.com"]
    and .configMethod == "DHCP" and .mac == "00:00:5e:00:53:01" and .mtu == 1500
    and .channel == "36" and .band == "5" and .width == "80" and .phyMode == "802.11ax" and .txRate == 1200
    and .signal == -58 and .noise == -92 and .signalLevel == "ok" and .security == "WPA3 Personal"
    and .wifiProblem == null and .status == "Wi-Fi · 192.0.2.10" and .level == "ok"' read $(on wifi) TOOLSY_EVENT=refresh
keys=$($jq -c keys "$data/out")
expect '.ipv6All[0].subtitle == "Временный" and .ipv6All[1].subtitle == "Постоянный"' read $(on wifi) TOOLSY_EVENT=network TOOLSY_LOCALE=ru-ru
expect '.channel == "6" and .band == "2" and .width == "20" and .signalLevel == "error" and .security == "None"' read $(on weak) TOOLSY_EVENT=wake
expect '.security == "Нет"' read $(on weak) TOOLSY_LOCALE=ru
expect '.address == "192.0.2.10" and .dns != null and .channel == null and .signal == null and (.wifiProblem | startswith("Wi-Fi details could not be read"))' read $(on no-profile)
expect '.interface == "en7" and .kind == "Desk \"LAN\" \\ 🙂" and .ipv4 == null and .mask == null and .router == null
    and .address == "2001:db8::7" and .ipv6 == "2001:db8::7" and .ipv6All == [{"title": "2001:db8::7", "subtitle": "Assigned"}]
    and .linkLocal == null and .dns == null and .configMethod == "Manually" and .mtu == 9000
    and .channel == null and .wifiProblem == null and .status == "Desk \"LAN\" \\ 🙂 · 2001:db8::7"' read $(on ipv6)
expect '.configMethod == "Вручную"' read $(on ipv6) TOOLSY_LOCALE=ru
expect '.interface == "utun4" and .kind == "VPN" and .address == "192.0.2.66" and .mask == "255.255.255.255" and .mac == null and .configMethod == null' read $(on vpn)
expect '.interface == null and .address == null and .dns == null and .signal == null and .status == "Not connected" and .level == "off"' read $(on offline)
[ "$($jq -c keys "$data/out")" = "$keys" ] || problem "offline: reports other keys than online, so stale values would stay: $($jq -c keys "$data/out")"
expect '.status == "Нет подключения"' read $(on offline) TOOLSY_LOCALE=ru
expect '.status == "Not connected"' read $(on offline) TOOLSY_LOCALE="$(printf 'Ли "Ко" \\ \001 🙂')"
expect_failure read $(on vanished)
expect_failure read $(on strange)

# This Mac, as it is: one valid patch. Its values are this Mac's own and are not printed.
label="read on this Mac"
run read
if [ "$status" -ne 0 ]; then
    problem "$label: exit $status: $(tail -n 1 "$data/err")"
elif ! $jq -e -s --argjson keys "$keys" 'length == 1 and (.[0] | keys == $keys and (.status | type) == "string"
        and (if .interface then .level == "ok" and (.address | type) == "string" else .level == "off" end))' "$data/out" >/dev/null 2>&1; then
    problem "$label: unexpected patch (not shown, it holds this Mac's addresses)"
else
    printf 'ok   %s → %s keys, level %s\n' "$label" "$($jq 'length' "$data/out")" "$($jq -r .level "$data/out")"
fi

if [ "$failures" -ne 0 ]; then
    echo "$failures check(s) failed" >&2
    exit 1
fi
echo "all checks passed"
