#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# An explicit SDK override supports machines with a partially upgraded toolchain.
SDK="${BROWSER_SDK:-$(xcrun --show-sdk-path)}"
if [[ -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]]; then
    SDK="${BROWSER_SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
fi
ARCH="$(uname -m)"
FLAGS=(-sdk "$SDK" -module-cache-path "$PWD/.build/cache" -target "$ARCH-apple-macosx14.0")
mkdir -p .build/manual build/Browser.app/Contents/MacOS
xcrun swiftc "${FLAGS[@]}" -emit-module -emit-library -enable-testing -module-name BrowserCore Sources/BrowserCore/Session.swift -o .build/manual/libBrowserCore.dylib -emit-module-path .build/manual/BrowserCore.swiftmodule
if [[ "${1:-}" == "test" ]]; then
    xcrun swiftc "${FLAGS[@]}" -I .build/manual -L .build/manual -lBrowserCore -Xlinker -rpath -Xlinker "$PWD/.build/manual" scripts/CoreChecks.swift -o .build/manual/checks
    .build/manual/checks
    exit
fi
# Link the core statically so the app is self-contained.
xcrun swiftc "${FLAGS[@]}" -O -parse-as-library -emit-object -module-name BrowserCore Sources/BrowserCore/Session.swift -o .build/manual/BrowserCore.o
xcrun swiftc "${FLAGS[@]}" -O -I .build/manual Sources/Browser/*.swift .build/manual/BrowserCore.o -o build/Browser.app/Contents/MacOS/Browser
cp scripts/Info.plist build/Browser.app/Contents/Info.plist
codesign --force --sign - build/Browser.app
printf 'Built %s/build/Browser.app\n' "$PWD"
