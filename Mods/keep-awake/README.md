# Keep Awake

A Toolsy mod that keeps the Mac from going to sleep on its own: for 30 minutes, an hour, two hours,
or until you switch it off. Optionally the display stays on too. When the time is up the mod
switches itself off.

The page and the dashboard tile show whether it is on, how much time is left and when it ends; the
tile can switch it on and off and change the duration.

## What it runs

| Command | Runs | When |
| --- | --- | --- |
| `hold` (service) | `/usr/bin/caffeinate -i -t SECONDS`, or `-di` with **Keep the display on**, without `-t` for **Indefinitely** | while the mod is on |
| `start`, `stop` | `date`, `jq` | the main switch, the tile's buttons |
| `retime` | `date`, `jq` | a new duration chosen while on: it counts from that moment |
| `status` | `date`, `jq` | every 15 s while the panel is open, and after the Mac wakes |

`caffeinate` holds the same power assertion the system uses when an app asks the Mac to stay awake;
it ends when the process ends. The end of the hold is the setting `until`, so a hold survives
quitting Toolsy: when Toolsy starts again it restarts the service with the time that is left. When
`caffeinate`'s timeout ends it exits with status 0, which switches the mod off. Its timer may not
count the time the Mac spends asleep, so after a wake `status` switches off a hold whose end has passed.

## What it never does

It needs no administrator access, changes no system setting (`pmset` is untouched) and stops
nothing but its own `caffeinate`. Closing the lid or choosing **Sleep** still puts the Mac to sleep.

## Development

```sh
./test.sh     # runs every command as Toolsy does; starts caffeinate for a few seconds
./build.sh    # build/keep-awake.toolsymod
```
