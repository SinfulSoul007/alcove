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
STORE_SOURCES=()
for source in Sources/Browser/*.swift; do [[ "$source" == "Sources/Browser/main.swift" ]] || STORE_SOURCES+=("$source"); done
run_website_checks() {
    xcrun swiftc "${FLAGS[@]}" -parse-as-library -I "$MANUAL" -L "$MANUAL" -lBrowserCore -Xlinker -rpath -Xlinker "$MANUAL" "${STORE_SOURCES[@]}" scripts/ProfileWebsiteChecks.swift -o "$MANUAL/profile-website-checks"
    FIXTURE_PORT_FILE="$(mktemp "$MANUAL/profile-fixture.XXXXXX")"
    python3 scripts/ProfileFixture.py "$FIXTURE_PORT_FILE" > "$MANUAL/profile-fixture.log" 2>&1 &
    FIXTURE_PID=$!
    trap 'kill "$FIXTURE_PID" 2>/dev/null || true; wait "$FIXTURE_PID" 2>/dev/null || true; rm -f "$FIXTURE_PORT_FILE"' EXIT
    for attempt in {1..500}; do [[ -s "$FIXTURE_PORT_FILE" ]] && break; kill -0 "$FIXTURE_PID" 2>/dev/null || break; sleep 0.02; done
    [[ -s "$FIXTURE_PORT_FILE" ]] || { cat "$MANUAL/profile-fixture.log"; exit 1; }
    ALCOVE_PROFILE_FIXTURE_URL="http://127.0.0.1:$(cat "$FIXTURE_PORT_FILE")/" "$MANUAL/profile-website-checks"
    kill "$FIXTURE_PID" 2>/dev/null || true
    wait "$FIXTURE_PID" 2>/dev/null || true
    rm -f "$FIXTURE_PORT_FILE"
    trap - EXIT

}
if [[ "${1:-}" == "quick-core-test" ]]; then
    xcrun swiftc "${FLAGS[@]}" -I "$MANUAL" -L "$MANUAL" -lBrowserCore -Xlinker -rpath -Xlinker "$MANUAL" scripts/QuickBrowseCoreChecks.swift -o "$MANUAL/quick-core-checks"
    "$MANUAL/quick-core-checks"
    exit
fi
if [[ "${1:-}" == "website-test" ]]; then run_website_checks; exit; fi
if [[ "${1:-}" == "command-import-test" ]]; then
    xcrun swiftc "${FLAGS[@]}" -parse-as-library -I "$MANUAL" -L "$MANUAL" -lBrowserCore -Xlinker -rpath -Xlinker "$MANUAL" "${STORE_SOURCES[@]}" scripts/ProfileCommandImportChecks.swift -o "$MANUAL/profile-command-import-checks"
    "$MANUAL/profile-command-import-checks"
    exit
fi
if [[ "${1:-}" == "favorites-test" ]]; then
    xcrun swiftc "${FLAGS[@]}" -parse-as-library -I "$MANUAL" -L "$MANUAL" -lBrowserCore -Xlinker -rpath -Xlinker "$MANUAL" "${STORE_SOURCES[@]}" scripts/ProfileFavoriteChecks.swift -o "$MANUAL/profile-favorite-checks"
    "$MANUAL/profile-favorite-checks"
    exit
fi
if [[ "${1:-}" == "lifecycle-test" ]]; then
    xcrun swiftc "${FLAGS[@]}" -parse-as-library -I "$MANUAL" -L "$MANUAL" -lBrowserCore -Xlinker -rpath -Xlinker "$MANUAL" "${STORE_SOURCES[@]}" scripts/ProfileLifecycleChecks.swift -o "$MANUAL/profile-lifecycle-checks"
    "$MANUAL/profile-lifecycle-checks"
    exit
fi
if [[ "${1:-}" == "test" ]]; then
    xcrun swiftc "${FLAGS[@]}" -I "$MANUAL" -L "$MANUAL" -lBrowserCore -Xlinker -rpath -Xlinker "$MANUAL" scripts/CoreChecks.swift -o "$MANUAL/checks"
    "$MANUAL/checks"
    xcrun swiftc "${FLAGS[@]}" -parse-as-library -I "$MANUAL" -L "$MANUAL" -lBrowserCore -Xlinker -rpath -Xlinker "$MANUAL" "${STORE_SOURCES[@]}" scripts/StoreChecks.swift -o "$MANUAL/store-checks"
    "$MANUAL/store-checks"
    xcrun swiftc "${FLAGS[@]}" -parse-as-library -I "$MANUAL" -L "$MANUAL" -lBrowserCore -Xlinker -rpath -Xlinker "$MANUAL" "${STORE_SOURCES[@]}" scripts/ProfileStoreChecks.swift -o "$MANUAL/profile-store-checks"
    "$MANUAL/profile-store-checks"
    xcrun swiftc "${FLAGS[@]}" -parse-as-library -I "$MANUAL" -L "$MANUAL" -lBrowserCore -Xlinker -rpath -Xlinker "$MANUAL" "${STORE_SOURCES[@]}" scripts/ProfileCommandImportChecks.swift -o "$MANUAL/profile-command-import-checks"
    "$MANUAL/profile-command-import-checks"
    xcrun swiftc "${FLAGS[@]}" -parse-as-library -I "$MANUAL" -L "$MANUAL" -lBrowserCore -Xlinker -rpath -Xlinker "$MANUAL" "${STORE_SOURCES[@]}" scripts/ProfileFavoriteChecks.swift -o "$MANUAL/profile-favorite-checks"
    "$MANUAL/profile-favorite-checks"
    xcrun swiftc "${FLAGS[@]}" -parse-as-library -I "$MANUAL" -L "$MANUAL" -lBrowserCore -Xlinker -rpath -Xlinker "$MANUAL" "${STORE_SOURCES[@]}" scripts/ProfileLifecycleChecks.swift -o "$MANUAL/profile-lifecycle-checks"
    "$MANUAL/profile-lifecycle-checks"
    xcrun swiftc "${FLAGS[@]}" -I "$MANUAL" -L "$MANUAL" -lBrowserCore -Xlinker -rpath -Xlinker "$MANUAL" scripts/QuickBrowseCoreChecks.swift -o "$MANUAL/quick-core-checks"
    "$MANUAL/quick-core-checks"
    xcrun swiftc "${FLAGS[@]}" -I "$MANUAL" -L "$MANUAL" -lBrowserCore -Xlinker -rpath -Xlinker "$MANUAL" scripts/AppearanceChecks.swift -o "$MANUAL/appearance-checks"
    "$MANUAL/appearance-checks"
    xcrun swiftc "${FLAGS[@]}" -I "$MANUAL" -L "$MANUAL" -lBrowserCore -Xlinker -rpath -Xlinker "$MANUAL" scripts/ProfileChecks.swift -o "$MANUAL/profile-checks"
    "$MANUAL/profile-checks"
    xcrun swiftc "${FLAGS[@]}" -parse-as-library -I "$MANUAL" -L "$MANUAL" -lBrowserCore -Xlinker -rpath -Xlinker "$MANUAL" Sources/Browser/UpdateController.swift scripts/UpdateChecks.swift -o "$MANUAL/update-checks"
    "$MANUAL/update-checks"
    run_website_checks
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
