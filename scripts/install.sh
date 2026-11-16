#!/bin/bash
# Builds Toolsy and installs it into /Applications, replacing and restarting a running copy.
# TOOLSY_INSTALL_DIR overrides the destination folder.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
destination="${TOOLSY_INSTALL_DIR:-/Applications}/Toolsy.app"

"$root/scripts/build-app.sh" > /dev/null

# SIGTERM is a normal quit for Toolsy: it stops the services of its mods before exiting.
if pkill -TERM -x Toolsy; then
    for _ in $(seq 50); do
        pgrep -x Toolsy > /dev/null || break
        sleep 0.1
    done
fi

rm -rf "$destination"
ditto "$root/build/Toolsy.app" "$destination"
open "$destination"
echo "$destination"
