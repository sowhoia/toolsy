# Builds the patch of read.sh. Input: system_profiler's Wi-Fi report, or null. Every --arg is text
# read from the system, empty when unknown; $interface is empty when the Mac is offline. Every key
# is always present, null when unknown, so nothing stale stays on the page.

def text: if . == "" then null else . end;
def lines: split("\n") | map(select(. != ""));

# The current network of $interface in system_profiler's report: channel "36 (5GHz, 80MHz)",
# signal "-46 dBm / -92 dBm", security "spairport_security_mode_wpa2_personal".
def wifi:
    [.SPAirPortDataType[]?.spairport_airport_interfaces[]? | select(._name == $interface)
     | .spairport_current_network_information? // empty][0] // {}
    | (.spairport_network_channel // "" | capture("^(?<channel>[0-9]+)( \\((?<band>[0-9.]+)GHz(, (?<width>[0-9]+)MHz)?\\))?") // {}) as $channel
    | (.spairport_signal_noise // "" | capture("^(?<signal>-?[0-9]+) dBm / (?<noise>-?[0-9]+) dBm") // {}) as $levels
    | ($levels.signal // null | if . then tonumber else null end) as $signal
    | {channel: $channel.channel, band: $channel.band, width: $channel.width,
       phyMode: .spairport_network_phymode, txRate: .spairport_network_rate,
       signal: $signal, noise: ($levels.noise // null | if . then tonumber else null end),
       signalLevel: (if $signal == null then null elif $signal >= -60 then "ok" elif $signal >= -70 then "warn" else "error" end),
       security: (.spairport_security_mode // null | if . == null then null
           else sub("^spairport_security_mode_"; "") | if . == "none" then $none
           else split("_") | map(if test("^(wpa|wep)") then ascii_upcase else (.[0:1] | ascii_upcase) + .[1:] end) | join(" ") end end)};

# Global IPv6 addresses as [address, kind]; the stable one is preferred, as temporary ones rotate.
. as $report
| ($ipv6 | lines | map(split(" "))) as $global
| (($ipv4 | text) // $global[0][0]) as $address
| {temporary: $temporary, stable: $stable, assigned: $assigned} as $kinds
| {
    interface: ($interface | text), kind: ($kind | text), address: $address,
    ipv4: ($ipv4 | text), mask: ($mask | text), router: ($router | text),
    ipv6: (($global | map(select(.[1] == "stable")) + $global)[0][0]),
    ipv6All: ($global | map({title: .[0], subtitle: $kinds[.[1]]}) | if . == [] then null else . end),
    linkLocal: ($linkLocal | text), router6: ($router6 | text),
    dns: ($servers | lines | if . == [] then null else . end),
    searchDomains: ($domains | lines | if . == [] then null else . end),
    configMethod: ($method | text), mac: ($mac | text), mtu: ($mtu | tonumber? // null),
    channel: null, band: null, width: null, phyMode: null, txRate: null, signal: null, noise: null,
    signalLevel: null, security: null, wifiProblem: ($wifiProblem | text)
  }
| . + (if $report == null then {} else ($report | wifi) end)
| .status = (if .interface then [.kind, .address] | map(select(.)) | join(" · ") else $offline end)
| .level = (if .interface then "ok" else "off" end)
