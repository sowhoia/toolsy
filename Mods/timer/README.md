# Focus Timer

A Toolsy mod for working in focused stretches: a work phase (25 minutes by default) followed by a
break (5 minutes). A system notification says when each phase ends. After the break the timer
waits until you start the next work phase.

Start, pause, resume and reset it on its page, on its dashboard tile (whose bar shows the progress
of the phase) or with the mod's main switch, which starts and pauses it.

## How it keeps time

The timer is three settings, so it survives quitting Toolsy: the phase, when the running phase ends
(wall-clock time) and the time left in a paused phase. Nothing counts ticks; time left is always the
end minus now.

| Command | Runs | When |
| --- | --- | --- |
| `wait` (service) | `sleep` until the phase ends, then reports the next phase and notifies | while the timer runs |
| `start`, `pause`, `reset` | `date`, `jq` | the buttons and the main switch |
| `show` | `date`, `jq` | every second while the panel is open, and after the Mac wakes |

Every command first settles phases that ended in the meantime, in order, as if it had been watching:
a break starts exactly when its work phase ended. That is what makes sleep harmless. `sleep` may
not count the time the Mac spends asleep, so after a wake the `wake` event runs `show`, which
settles the phase that ended during sleep at once; the same happens when Toolsy starts again with
the timer running. The service exits with status 0 after the break, which switches the mod off.

## What it never does

No administrator access, no network, no files: its state lives in Toolsy's settings for the mod.

## Development

```sh
./test.sh     # runs every command as Toolsy does, and a few seconds of the service
./build.sh    # build/timer.toolsymod
```
