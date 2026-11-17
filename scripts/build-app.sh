#!/bin/bash
# Builds build/Toolsy.app from the Swift packages.
#
#   scripts/build-app.sh             release build with the helper and toolsy-mod embedded
#   scripts/build-app.sh --debug     debug build of the app (faster to compile)
#   scripts/build-app.sh --app-only  skip the embedded tools (UI work that does not need them)
#
# TOOLSY_SIGN_IDENTITY selects a signing identity; the default "-" signs ad hoc, which is all
# the privileged helper needs (it pins the app by code directory hash).
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
configuration=release
app_only=false
for argument in "$@"; do
    case "$argument" in
        --debug) configuration=debug ;;
        --app-only) app_only=true ;;
        *) echo "usage: $0 [--debug] [--app-only]" >&2; exit 64 ;;
    esac
done
identity=${TOOLSY_SIGN_IDENTITY:--}
app="$root/build/Toolsy.app"

# Builds PRODUCT of the package in directory PACKAGE and copies it to OUTPUT. Call it as a plain
# command, never inside $(…): bash 3.2 ignores `set -e` there, so a failed build would go on with
# the binary of the previous one.
build_product() {
    local package=$1 product=$2 product_configuration=$3 output=$4 bin_path
    # The beta toolchain prints a "remark:" line per prebuilt module; drop them, keep everything else.
    (cd "$package" && swift build -c "$product_configuration" --product "$product" 2>&1) |
        { grep -v 'remark:' || true; } >&2
    bin_path=$(cd "$package" && swift build -c "$product_configuration" --show-bin-path)
    cp "$bin_path/$product" "$output"
}

sign() {
    codesign --force --options runtime --timestamp=none --sign "$identity" "$@"
}

# A release binary carries its whole symbol table, more than half of its size, and nothing reads it
# at run time. Stripping breaks the linker's ad hoc signature, which is removed first so that strip
# does not warn about it; the real signature comes afterwards.
slim() {
    codesign --remove-signature "$1"
    strip -rSTx "$1"
}

# Whatever an earlier build left must not pass for this one's, whichever step fails.
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Helpers"
build_product "$root" Toolsy "$configuration" "$app/Contents/MacOS/Toolsy"
if [ "$configuration" = release ]; then
    slim "$app/Contents/MacOS/Toolsy"
fi
cp "$root/Resources/Info.plist" "$app/Contents/Info.plist"
cp -R "$root"/Resources/*.lproj "$app/Contents/Resources/"
if [ -f "$root/Resources/AppIcon.icns" ]; then
    cp "$root/Resources/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
fi

if [ "$app_only" = false ]; then
    build_product "$root/Packages/ToolsyPrivileged" ToolsyHelper release "$app/Contents/Helpers/ToolsyHelper"
    slim "$app/Contents/Helpers/ToolsyHelper"
    sign --identifier app.toolsy.helper "$app/Contents/Helpers/ToolsyHelper"

    build_product "$root/Packages/ToolsyEngine" toolsy-mod release "$app/Contents/Helpers/toolsy-mod"
    slim "$app/Contents/Helpers/toolsy-mod"
    sign --identifier app.toolsy.mod-tool "$app/Contents/Helpers/toolsy-mod"
fi

# The hardened runtime (and no get-task-allow) keeps other processes of the user from
# injecting code into the app, which is the only client the helper accepts.
sign "$app"
codesign --verify --strict --deep "$app"
echo "$app"
