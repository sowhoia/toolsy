#!/bin/bash
# Builds the release of the tagged commit, checks it and, with --publish, publishes it on GitHub.
#
#   scripts/release.sh [--ad-hoc] [--skip-notarization] [--allow-beta] [--publish]
#
# HEAD must carry the tag vX.Y.Z of the version that Resources/Info.plist, ToolsyVersion.swift and the
# newest version of CHANGELOG.md name, and nothing may be uncommitted. The app is built with
# scripts/build-app.sh and signed with TOOLSY_SIGN_IDENTITY (a "Developer ID Application: …" identity),
# then notarized with the notarytool keychain profile TOOLSY_NOTARY_PROFILE and stapled. The zip is
# signed for Toolsy's own updater with TOOLSY_UPDATE_KEY (default ~/.config/toolsy/update-signing.key), the
# key whose public half is ToolsyUpdatePublicKey in Resources/Info.plist. dist/release/ is made anew on
# every run and receives:
#
#   Toolsy-X.Y.Z.zip          the app
#   Toolsy-X.Y.Z.zip.sig      the update key's signature of the zip, without which Toolsy only links to
#                             the release instead of installing it
#   <mod>.toolsymod           the example mods (not vpn-protector)
#   SHA256SUMS                the checksums of the files above
#   release-notes.md          the version's section of CHANGELOG.md, the text of the GitHub release
#   Toolsy-X.Y.Z-dSYMs.zip    the debug symbols of the app, its helper and toolsy-mod, to symbolicate
#                             crash reports; kept, never published: they name this Mac's folders and user
#
#   --ad-hoc              allow signing ad hoc (TOOLSY_SIGN_IDENTITY unset or "-")
#   --skip-notarization   allow going on without TOOLSY_NOTARY_PROFILE
#   --allow-beta          allow a beta Xcode
#   --publish             create the GitHub release with gh; without it the command is printed
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

ad_hoc=false
skip_notarization=false
allow_beta=false
publish=false
for argument in "$@"; do
    case "$argument" in
        --ad-hoc) ad_hoc=true ;;
        --skip-notarization) skip_notarization=true ;;
        --allow-beta) allow_beta=true ;;
        --publish) publish=true ;;
        *) echo "usage: $0 [--ad-hoc] [--skip-notarization] [--allow-beta] [--publish]" >&2; exit 64 ;;
    esac
done

fail() {
    echo "release.sh: $*" >&2
    exit 1
}

# Everything is checked before anything is built. Command output is captured in a variable of its
# own first: a failure inside `[ "$(…)" ]` would go unnoticed.

# What is released is exactly the tagged commit.
changes=$(git status --porcelain)
[ -z "$changes" ] || fail "commit or remove these changes first:
$changes"
head_tags=$(git tag --points-at HEAD)
tag=$(printf '%s\n' "$head_tags" | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' || true)
[ -n "$tag" ] || fail "HEAD has no tag vX.Y.Z"
case $tag in *$'\n'*) fail "HEAD has several version tags: ${tag//$'\n'/ }" ;; esac
version=${tag#v}

plist_version=$(plutil -extract CFBundleShortVersionString raw -o - Resources/Info.plist)
code_version=$(sed -nE 's/^[[:space:]]*public static let current = "([^"]*)"$/\1/p' \
    Packages/ToolsyShared/Sources/ToolsyShared/ToolsyVersion.swift)
changelog_version=$(awk '/^## \[[0-9]+\.[0-9]+\.[0-9]+\] - [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/ {
    sub(/^## \[/, ""); sub(/\].*/, ""); print; exit }' CHANGELOG.md)
mismatches=
[ "$plist_version" = "$version" ] ||
    mismatches+=$'\n'"  CFBundleShortVersionString in Resources/Info.plist: ${plist_version:-none}"
[ "$code_version" = "$version" ] ||
    mismatches+=$'\n'"  ToolsyVersion.current in ToolsyShared/ToolsyVersion.swift: ${code_version:-none}"
[ "$changelog_version" = "$version" ] ||
    mismatches+=$'\n'"  the newest version in CHANGELOG.md (## [X.Y.Z] - YYYY-MM-DD): ${changelog_version:-none}"
[ -z "$mismatches" ] || fail "the tag is $tag, but$mismatches"

xcode=$(xcodebuild -version) || fail "xcodebuild -version failed: a release is built with Xcode"
compiler=$(swift --version 2>&1)
printf '%s\n%s\n' "$xcode" "$compiler"
# Apple ships a beta as Xcode-beta.app. Its build number tells nothing: releases end in a letter too (16A242d).
developer_dir=${DEVELOPER_DIR:-$(xcode-select -p)}
case $(printf '%s' "$developer_dir" | tr '[:upper:]' '[:lower:]') in
    *beta*) [ "$allow_beta" = true ] || fail "$developer_dir is a beta Xcode (--allow-beta builds with it anyway)" ;;
esac

identity=${TOOLSY_SIGN_IDENTITY:--}
[ "$identity" != - ] || [ "$ad_hoc" = true ] ||
    fail "set TOOLSY_SIGN_IDENTITY to a Developer ID Application identity (--ad-hoc signs ad hoc instead)"
profile=${TOOLSY_NOTARY_PROFILE-}
[ -n "$profile" ] || [ "$skip_notarization" = true ] ||
    fail "set TOOLSY_NOTARY_PROFILE to a notarytool keychain profile (--skip-notarization goes on without)"

# The beta toolchain prints a "remark:" line per prebuilt module; drop them, keep everything else.
sign_update() {
    swift "$root/scripts/sign-update.swift" "$@" 2> >(grep -v 'remark:' >&2)
}
update_key=${TOOLSY_UPDATE_KEY:-$HOME/.config/toolsy/update-signing.key}
[ -f "$update_key" ] ||
    fail "no update signing key at $update_key: set TOOLSY_UPDATE_KEY to the key ToolsyUpdatePublicKey in Resources/Info.plist names"
sign_update --check "$update_key"

out="$root/dist/release"
app="$root/build/Toolsy.app"
binaries=("$app/Contents/MacOS/Toolsy" "$app/Contents/Helpers/ToolsyHelper" "$app/Contents/Helpers/toolsy-mod")
rm -rf "$out"
mkdir -p "$out"
work=$(mktemp -d "${TMPDIR:-/tmp}/toolsy-release.XXXXXX")
trap 'rm -rf "$work"' EXIT

# Without resource forks and extended attributes: no __MACOSX folder or ._ files in the archive.
archive() {
    ditto -c -k --norsrc --noextattr --noqtn --noacl --keepParent "$1" "$2"
}

echo "Building Toolsy $version" >&2
TOOLSY_SIGN_IDENTITY=$identity "$root/scripts/build-app.sh" > /dev/null

codesign --verify --deep --strict --verbose=2 "$app"
for binary in "${binaries[@]}"; do
    name=${binary#"$app/"}
    lipo "$binary" -verify_arch arm64 x86_64 || fail "$name is not universal: $(lipo -archs "$binary")"
    for architecture in arm64 x86_64; do
        details=$(codesign --display --verbose=2 --arch "$architecture" "$binary" 2>&1) ||
            fail "$name ($architecture) is not signed: $details"
        flags=$(printf '%s\n' "$details" | sed -n 's/^CodeDirectory .* flags=\(0x[0-9a-f]*([^)]*)\).*/\1/p')
        case $flags in
            *runtime*) ;;
            *) fail "$name ($architecture) is not signed with the hardened runtime: flags ${flags:-unknown}" ;;
        esac
        team=$(printf '%s\n' "$details" | sed -n 's/^TeamIdentifier=//p')
        if [ "$identity" != - ]; then
            case $team in '' | 'not set') fail "$name ($architecture) is signed without a team identifier" ;; esac
        fi
    done
    entitlements=$(codesign --display --entitlements - --xml "$binary" 2>/dev/null) ||
        fail "the entitlements of $name cannot be read"
    case $entitlements in *get-task-allow*) fail "$name may be debugged by other processes (get-task-allow)" ;; esac
done

if [ -n "$profile" ]; then
    echo "Notarizing" >&2
    archive "$app" "$work/Toolsy.zip"
    submitted=0
    result=$(xcrun notarytool submit "$work/Toolsy.zip" --keychain-profile "$profile" --wait --output-format json) ||
        submitted=$?
    id=$(printf '%s' "$result" | /usr/bin/jq -r '.id // empty' 2>/dev/null || true)
    status=$(printf '%s' "$result" | /usr/bin/jq -r '.status // empty' 2>/dev/null || true)
    if [ "$submitted" -ne 0 ] || [ "$status" != Accepted ]; then
        printf '%s\n' "$result" >&2
        [ -z "$id" ] || xcrun notarytool log "$id" --keychain-profile "$profile" >&2 || true
        fail "notarization did not succeed (status ${status:-unknown})"
    fi
    xcrun stapler staple "$app"
    spctl --assess --type execute -vv "$app"
fi

zip="$out/Toolsy-$version.zip"
archive "$app" "$zip"
entries=$(zipinfo -1 "$zip")
if printf '%s\n' "$entries" | grep -E '(^|/)(__MACOSX/|\._)' >&2; then
    fail "$(basename "$zip") holds resource forks or AppleDouble files"
fi
# What users unpack must still be signed as built.
mkdir "$work/unpacked"
ditto -x -k "$zip" "$work/unpacked"
codesign --verify --deep --strict "$work/unpacked/Toolsy.app"
sign_update "$update_key" "$version" "$zip"

symbols="$work/Toolsy-$version-dSYMs"
mkdir "$symbols"
uuids() {
    dwarfdump --uuid "$1" | awk '{ print $2 }' | sort
}
for binary in "${binaries[@]}"; do
    name=$(basename "$binary")
    [ "$name" != Toolsy ] || name=Toolsy.app
    expected=$(uuids "$binary")
    found=$(uuids "$root/build/$name.dSYM")
    if [ -z "$expected" ] || [ "$found" != "$expected" ]; then
        fail "build/$name.dSYM does not belong to this build"
    fi
    ditto "$root/build/$name.dSYM" "$symbols/$name.dSYM"
done
archive "$symbols" "$out/Toolsy-$version-dSYMs.zip"

# vpn-protector was not attached to 1.0.0 either.
packed=$("$root/scripts/build-mods.sh")
while IFS= read -r mod; do
    case $(basename "$mod") in
        vpn-protector.toolsymod) ;;
        *) cp "$mod" "$out/" ;;
    esac
done <<< "$packed"

# The symbols stay out: they are for the one who reads crash reports, and they hold this Mac's paths.
assets=("Toolsy-$version.zip" "Toolsy-$version.zip.sig")
for mod in "$out"/*.toolsymod; do
    assets+=("$(basename "$mod")")
done
(cd "$out" && shasum -a 256 "${assets[@]}" > SHA256SUMS && shasum -a 256 -c SHA256SUMS > /dev/null)
assets+=(SHA256SUMS)

notes="$out/release-notes.md"
awk -v heading="## [$version] - " '
    index($0, heading) == 1 { inside = 1; next }
    inside && (/^## / || /^\[[^]]*\]: /) { exit }
    inside { lines[++count] = $0 }
    END {
        first = 1; while (first <= count && lines[first] == "") first++
        last = count; while (last >= first && lines[last] == "") last--
        for (line = first; line <= last; line++) print lines[line]
    }' CHANGELOG.md > "$notes"
[ -s "$notes" ] || fail "CHANGELOG.md has no text under the heading of $version"

# --verify-tag: gh would otherwise create a missing tag on the remote from the default branch.
command=(gh release create "$tag")
for asset in "${assets[@]}"; do
    command+=("$out/$asset")
done
command+=(--verify-tag --title "Toolsy $version" --notes-file "$notes")
echo "Toolsy $version is in ${out#"$root/"}:"
cat "$out/SHA256SUMS"
if [ "$publish" = true ]; then
    "${command[@]}"
else
    echo "To publish it:"
    printf '%q ' "${command[@]}"
    echo
fi
