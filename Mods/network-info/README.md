# Network Info

A Toolsy mod that shows what the network looks like right now: the connection (Wi-Fi, Ethernet,
VPN) and its interface, IPv4 and IPv6 addresses, router, DNS servers and search domains, how the
address was configured, the subnet mask, MTU and MAC address, and for Wi-Fi the channel, band,
width, standard, signal, noise, link rate and security. Values can be copied with a click; **Copy
All** copies a summary. A dashboard tile shows the address, with the router, DNS server and signal
when expanded. **Copy Address**, a quick control, copies the address from the mod's card and from the
menu of Toolsy's menu bar icon.

## What it runs

One command, `read`, when the panel opens, every 30 seconds while it is open, when the network
changes and after the Mac wakes:

| Tool | For |
| --- | --- |
| `scutil` (`show State:/Network/Global/IPv4`, `…/IPv6`, `…/DNS`, `Setup:/Network/Service/<id>/Interface`, `…/IPv4`) | the primary interface and service, routers, DNS, the service's name and how it is configured |
| `ifconfig <interface>` | addresses, mask, MTU, MAC address |
| `system_profiler -detailLevel basic SPAirPortDataType -json` | Wi-Fi details, only when the connection is Wi-Fi; takes up to a few seconds |
| `jq` | turns all of it into the patch (`scripts/patch.jq`) |

## What it never does

It never contacts a server, so it does not show a public IP address. It needs no administrator
access and no location permission: macOS gives the Wi-Fi network's name and the access point's
address only to apps allowed to use the location, so the mod does not read them, and leaves out
any value macOS does not report.

## Development

```sh
./test.sh     # runs the command against fixtures of many networks, then once on this Mac
./build.sh    # build/network-info.toolsymod
```

The fixtures use documentation addresses (`192.0.2.0/24`, `2001:db8::/32`, `example.com`); the run on
this Mac checks only the shape of the patch and prints none of its values.
