#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
LAYOUT_SDK="${BROWSER_SDK:-$(xcrun --show-sdk-path)}"
if [[ -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]]; then
    LAYOUT_SDK="${BROWSER_SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
fi
LAYOUT_ARCH="$(uname -m)"
LAYOUT_BUILD="$PWD/.build/layout-benchmark/$LAYOUT_ARCH"
LAYOUT_OUTPUT="${1:-work/layout-benchmark.csv}"
mkdir -p "$LAYOUT_BUILD" "$PWD/.build/cache" "$(dirname "$LAYOUT_OUTPUT")"
LAYOUT_FLAGS=(-sdk "$LAYOUT_SDK" -module-cache-path "$PWD/.build/cache" -target "$LAYOUT_ARCH-apple-macosx14.0" -O)
xcrun swiftc "${LAYOUT_FLAGS[@]}" -emit-module -emit-library -module-name BrowserCore Sources/BrowserCore/*.swift -o "$LAYOUT_BUILD/libBrowserCore.dylib" -emit-module-path "$LAYOUT_BUILD/BrowserCore.swiftmodule"
LAYOUT_SOURCES=()
for source in Sources/Browser/*.swift; do
    [[ "$source" == "Sources/Browser/main.swift" ]] || LAYOUT_SOURCES+=("$source")
done
xcrun swiftc "${LAYOUT_FLAGS[@]}" -parse-as-library -I "$LAYOUT_BUILD" -L "$LAYOUT_BUILD" -lBrowserCore -Xlinker -rpath -Xlinker "$LAYOUT_BUILD" "${LAYOUT_SOURCES[@]}" scripts/LayoutBenchmark.swift -o "$LAYOUT_BUILD/layout-benchmark"
printf 'Browser source revision: %s\n' "$(git rev-parse HEAD)"
if git diff --quiet -- Sources/Browser Sources/BrowserCore; then
    printf 'Browser source matches that revision.\n'
else
    printf 'Browser sources have uncommitted changes; record them with these measurements.\n'
fi
exec "$LAYOUT_BUILD/layout-benchmark" "$LAYOUT_OUTPUT"
