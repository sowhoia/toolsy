#!/bin/sh
# Packs the installable mod:
#   build/network-info/            mod.json, scripts/
#   build/network-info.toolsymod   the same files zipped, mod.json at the archive root
set -eu
cd "$(dirname "$0")"

stage=build/network-info
archive=build/network-info.toolsymod

rm -rf "$stage" "$archive"
mkdir -p "$stage/scripts"
cp mod.json "$stage/mod.json"
cp scripts/read.sh scripts/patch.jq "$stage/scripts/"

# Every program the manifest starts must be in the staged mod.
/usr/bin/jq -r '.commands[] | .exec // empty' mod.json | sort -u | while IFS= read -r file; do
    if [ ! -f "$stage/$file" ] || [ ! -x "$stage/$file" ]; then
        echo "build.sh: mod.json runs $file, which is not staged" >&2
        exit 1
    fi
done

(cd "$stage" && zip -q -X -r "../$(basename "$archive")" .)
echo "$archive"
