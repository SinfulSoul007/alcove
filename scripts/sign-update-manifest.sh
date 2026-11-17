#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/alcove-sign-update.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
sdk="$(xcrun --show-sdk-path)"
sdk_26_5=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
if [[ -d "$sdk_26_5" ]]; then sdk="$sdk_26_5"; fi
xcrun swiftc -sdk "$sdk" -target "$(uname -m)-apple-macosx14.0" -parse-as-library \
    -module-cache-path "$scratch/modules" \
    "$root/Sources/BrowserCore/Updates.swift" "$root/Sources/BrowserCore/UpdateReleaseManifest.swift" \
    "$root/scripts/SignUpdateManifest.swift" -o "$scratch/sign-update-manifest"
"$scratch/sign-update-manifest" "$@"
