#!/bin/bash
# Builds every mod in Mods/, checks each packed file with toolsy-mod (the same checks the app
# runs at install time) and collects them in dist/.
# Each mod provides a build.sh that leaves build/<name>.toolsymod next to itself.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
engine="$root/Packages/ToolsyEngine"
# The beta toolchain prints a "remark:" line per prebuilt module; drop them, keep everything else.
(cd "$engine" && swift build -c release --product toolsy-mod 2>&1 | { grep -v 'remark:' || true; }) >&2
validator="$(cd "$engine" && swift build -c release --show-bin-path)/toolsy-mod"

mkdir -p "$root/dist"
for mod in "$root"/Mods/*/; do
    name=$(basename "$mod")
    "$mod/build.sh" >&2
    "$validator" validate "$mod/build/$name.toolsymod" >&2
    cp "$mod/build/$name.toolsymod" "$root/dist/$name.toolsymod"
    echo "$root/dist/$name.toolsymod"
done
