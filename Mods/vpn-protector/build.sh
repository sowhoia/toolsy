#!/bin/sh
# Builds the release binary and packs the installable mod:
#   build/vpn-protector/            mod.json, bin/vpn-protector (universal: arm64 and x86_64)
#   build/vpn-protector.toolsymod   the same files zipped, mod.json at the archive root
set -eu
cd "$(dirname "$0")"

stage=build/vpn-protector
archive=build/vpn-protector.toolsymod
log=$(mktemp)
trap 'rm -f "$log"' EXIT

# macOS 26 runs on Intel Macs too.
for architecture in arm64 x86_64; do
    if ! swift build -c release --arch "$architecture" --product vpn-protector >"$log" 2>&1; then
        grep -v 'remark:' "$log" >&2
        echo "build.sh: swift build failed" >&2
        exit 1
    fi
done
arm64=$(swift build -c release --arch arm64 --show-bin-path)/vpn-protector
x86_64=$(swift build -c release --arch x86_64 --show-bin-path)/vpn-protector

rm -rf "$stage" "$archive"
mkdir -p "$stage/bin"
cp mod.json "$stage/mod.json"
lipo -create "$arm64" "$x86_64" -output "$stage/bin/vpn-protector"
chmod 755 "$stage/bin/vpn-protector"

# Every program the manifest starts must be in the staged mod.
/usr/bin/jq -r '.commands[] | .exec // empty' mod.json | sort -u | while IFS= read -r file; do
    if [ ! -f "$stage/$file" ] || [ ! -x "$stage/$file" ]; then
        echo "build.sh: mod.json runs $file, which is not staged" >&2
        exit 1
    fi
done

(cd "$stage" && zip -q -X -r "../$(basename "$archive")" .)
echo "$archive"
