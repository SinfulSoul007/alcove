#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
SDK="${BROWSER_SDK:-$(xcrun --show-sdk-path)}"
if [[ -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]]; then
    SDK="${BROWSER_SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
fi
ARCH="${BROWSER_ARCH:-$(uname -m)}"
OUT="${BROWSER_OUTPUT:-build/Alcove.app}"
MANUAL="$PWD/.build/manual/$ARCH"
FLAGS=(-sdk "$SDK" -module-cache-path "$PWD/.build/cache" -target "$ARCH-apple-macosx14.0")
mkdir -p "$MANUAL" "$OUT/Contents/MacOS"
xcrun swiftc "${FLAGS[@]}" -emit-module -emit-library -enable-testing -module-name BrowserCore Sources/BrowserCore/*.swift -o "$MANUAL/libBrowserCore.dylib" -emit-module-path "$MANUAL/BrowserCore.swiftmodule"
if [[ "${1:-}" == "test" ]]; then
    xcrun swiftc "${FLAGS[@]}" -I "$MANUAL" -L "$MANUAL" -lBrowserCore -Xlinker -rpath -Xlinker "$MANUAL" scripts/CoreChecks.swift -o "$MANUAL/checks"
    "$MANUAL/checks"
    STORE_SOURCES=()
    for source in Sources/Browser/*.swift; do [[ "$source" == "Sources/Browser/main.swift" ]] || STORE_SOURCES+=("$source"); done
    xcrun swiftc "${FLAGS[@]}" -parse-as-library -I "$MANUAL" -L "$MANUAL" -lBrowserCore -Xlinker -rpath -Xlinker "$MANUAL" "${STORE_SOURCES[@]}" scripts/StoreChecks.swift -o "$MANUAL/store-checks"
    "$MANUAL/store-checks"
    xcrun swiftc "${FLAGS[@]}" -I "$MANUAL" -L "$MANUAL" -lBrowserCore -Xlinker -rpath -Xlinker "$MANUAL" scripts/AppearanceChecks.swift -o "$MANUAL/appearance-checks"
    "$MANUAL/appearance-checks"
    xcrun swiftc "${FLAGS[@]}" -I "$MANUAL" -L "$MANUAL" -lBrowserCore -Xlinker -rpath -Xlinker "$MANUAL" scripts/ProfileChecks.swift -o "$MANUAL/profile-checks"
    "$MANUAL/profile-checks"
    xcrun swiftc "${FLAGS[@]}" -parse-as-library -I "$MANUAL" -L "$MANUAL" -lBrowserCore -Xlinker -rpath -Xlinker "$MANUAL" Sources/Browser/UpdateController.swift scripts/UpdateChecks.swift -o "$MANUAL/update-checks"
    "$MANUAL/update-checks"
    exit
fi
xcrun swiftc "${FLAGS[@]}" -O -parse-as-library -whole-module-optimization -emit-object -module-name BrowserCore Sources/BrowserCore/*.swift -o "$MANUAL/BrowserCore.o"
xcrun swiftc "${FLAGS[@]}" -O -I "$MANUAL" Sources/Browser/*.swift "$MANUAL/BrowserCore.o" -o "$OUT/Contents/MacOS/Alcove"
mkdir -p "$OUT/Contents/Resources" .build/resources
if [[ ! -f .build/resources/Alcove.icns || scripts/Icon.swift -nt .build/resources/Alcove.icns ]]; then
    xcrun swiftc -sdk "$SDK" -module-cache-path "$PWD/.build/cache" -target "$(uname -m)-apple-macosx14.0" scripts/Icon.swift -o .build/resources/make-icon
    .build/resources/make-icon .build/resources/Alcove.iconset
fi
cp .build/resources/Alcove.icns "$OUT/Contents/Resources/Alcove.icns"
cp LICENSE "$OUT/Contents/Resources/LICENSE.txt"
cp scripts/Info.plist "$OUT/Contents/Info.plist"
if [[ -n "${BROWSER_BUNDLE_ID:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set CFBundleIdentifier $BROWSER_BUNDLE_ID" "$OUT/Contents/Info.plist"
fi
if [[ -n "${BROWSER_DISPLAY_NAME:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set CFBundleName $BROWSER_DISPLAY_NAME" "$OUT/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set CFBundleDisplayName $BROWSER_DISPLAY_NAME" "$OUT/Contents/Info.plist"
fi
codesign --force --sign - --options runtime --entitlements scripts/Entitlements.plist "$OUT"
printf 'Built %s/%s (%s, ad hoc signed, not notarized)\n' "$PWD" "$OUT" "$ARCH"
