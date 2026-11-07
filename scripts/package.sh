#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' scripts/Info.plist)"
APP="build/universal/Alcove.app"
./scripts/build.sh test
BROWSER_ARCH=arm64 BROWSER_OUTPUT=build/arm64/Alcove.app ./scripts/build.sh
BROWSER_ARCH=x86_64 BROWSER_OUTPUT=build/x86_64/Alcove.app ./scripts/build.sh
mkdir -p build/universal dist
# ditto preserves executable modes and bundle resources.
ditto build/arm64/Alcove.app "$APP"
lipo -create build/arm64/Alcove.app/Contents/MacOS/Alcove build/x86_64/Alcove.app/Contents/MacOS/Alcove -output "$APP/Contents/MacOS/Alcove"
codesign --force --sign - --options runtime --entitlements scripts/Entitlements.plist "$APP"
codesign --verify --deep --strict "$APP"
lipo "$APP/Contents/MacOS/Alcove" -verify_arch arm64 x86_64
ZIP="dist/Alcove-$VERSION-universal-unsigned-preview.zip"
DMG="dist/Alcove-$VERSION-universal-unsigned-preview.dmg"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
STAGE="$(mktemp -d "$PWD/.build/package.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/Alcove.app"
ln -s /Applications "$STAGE/Applications"
cp LICENSE "$STAGE/LICENSE.txt"
cat > "$STAGE/READ ME FIRST.txt" <<'NOTE'
Alcove 0.2 — UNSIGNED PREVIEW

macOS 14+, Apple Silicon or Intel. No Xcode or developer tools required.
Drag Alcove.app to Applications, then launch it from Applications.

This app is locally/ad hoc signed, NOT Developer ID signed or notarized.
macOS Gatekeeper may warn or block it. The project cannot certify it as safe.
Do not disable Gatekeeper or system security settings to run this preview.
If macOS blocks it, use the source build or wait for a notarized release.

Early testing build, not a stable daily-driver recommendation.
See https://github.com/SinfulSoul007/alcove for source, privacy notes,
known limitations, security reporting and checksums.
NOTE
(cd dist && shasum -a 256 "$(basename "$ZIP")" > SHA256SUMS.txt)
if hdiutil create -volname "Alcove Unsigned Preview" -srcfolder "$STAGE" -ov -format UDZO "$DMG"; then
    hdiutil verify "$DMG"
    (cd dist && shasum -a 256 "$(basename "$DMG")" >> SHA256SUMS.txt)
else
    # Disk-image device services are unavailable in some build sandboxes.
    # ZIP is still a complete installable app; never publish a partial DMG.
    rm -f "$DMG"
    printf 'DMG unavailable in this environment; the ZIP remains installable.\n'
fi
python3 scripts/verify-package.py "$ZIP"
printf 'Preview artifacts are in %s/dist\n' "$PWD"
