#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
dist="${1:-dist}"
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' scripts/Info.plist)
stem="Alcove-$version-universal-unsigned-preview"
zip="$dist/$stem.zip"
dmg="$dist/$stem.dmg"
test -s "$zip"
test -s "$dmg"
(cd "$dist" && shasum -a 256 -c SHA256SUMS.txt)
python3 scripts/verify-package.py "$zip"

stage=$(mktemp -d "${TMPDIR:-/tmp}/alcove-preview-check.XXXXXX")
stage="$(cd "$stage" && pwd -P)"
cleanup() {
    if mount | /usr/bin/grep -F " on $stage/dmg (" >/dev/null; then
        hdiutil detach "$stage/dmg" || return
    fi
    rm -rf "$stage"
}
trap cleanup EXIT
mkdir "$stage/zip" "$stage/dmg"
ditto -x -k "$zip" "$stage/zip"
hdiutil verify "$dmg"
hdiutil attach "$dmg" -readonly -nobrowse -mountpoint "$stage/dmg"
test -L "$stage/dmg/Applications"
test "$(readlink "$stage/dmg/Applications")" = /Applications
test -s "$stage/dmg/READ ME FIRST.txt"

for medium in zip dmg; do
    app="$stage/$medium/Alcove.app"
    codesign --verify --deep --strict --all-architectures "$app"
    lipo "$app/Contents/MacOS/Alcove" -verify_arch arm64 x86_64
    cmp scripts/Info.plist "$app/Contents/Info.plist"
    python3 scripts/refresh-website-protection.py --verify "$app/Contents/Resources/WebsiteProtection"
    diff -qr Resources/WebsiteProtection "$app/Contents/Resources/WebsiteProtection"
done
cmp "$stage/zip/Alcove.app/Contents/MacOS/Alcove" "$stage/dmg/Alcove.app/Contents/MacOS/Alcove"
hdiutil detach "$stage/dmg"
printf 'Verified the universal ZIP and DMG.\n'
