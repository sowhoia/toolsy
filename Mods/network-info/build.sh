#!/bin/bash
# Packs the installable mod:
#   build/network-info/            mod.json, scripts/
#   build/network-info.toolsymod   the same files zipped, mod.json at the archive root
# The same sources give the same archive, byte for byte.
set -euo pipefail
cd "$(dirname "$0")"

stage=build/network-info
archive=build/network-info.toolsymod

rm -rf "$stage" "$archive"
mkdir -p "$stage"
cp mod.json "$stage/mod.json"
cp -R scripts "$stage/scripts"
find "$stage" -name .DS_Store -delete
# Modes and times are part of the archive: 755 for folders and programs, 644 for the rest, one date.
chmod -R u=rwX,go=rX "$stage"
find "$stage" -exec touch -h -t 198001010000 {} +

# Every program the manifest starts must be in the staged mod.
/usr/bin/jq -r '.commands[] | .exec // empty' mod.json | sort -u | while IFS= read -r file; do
    if [ ! -f "$stage/$file" ] || [ ! -x "$stage/$file" ]; then
        echo "build.sh: mod.json runs $file, which is not staged" >&2
        exit 1
    fi
done

# Files in a fixed order, without folder entries or extra attributes (owner, more times).
(cd "$stage" && find . -type f | sed 's|^\./||' | LC_ALL=C sort | zip -q -X -D "../$(basename "$archive")" -@)
echo "$archive"
