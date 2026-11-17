#!/bin/bash
set +x
set -euo pipefail
umask 077

signing_value="${ALCOVE_UPDATE_SIGNING_KEY:?Configure Alcove’s release signing key before publishing this tag.}"
unset ALCOVE_UPDATE_SIGNING_KEY
cd "$(dirname "$0")/.."
tag="$1"
commit="$2"
dist="$3"
output="$4"
expected_tag=$(/usr/libexec/PlistBuddy -c 'Print AlcoveReleaseTag' scripts/Info.plist)
public_key=$(/usr/libexec/PlistBuddy -c 'Print AlcoveUpdateSigningPublicKey' scripts/Info.plist)
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' scripts/Info.plist)
test "$tag" = "$expected_tag"
test -n "$public_key"
stem="$dist/Alcove-$version-universal-unsigned-preview"
test -s "$stem.dmg"
test -s "$stem.zip"
(cd "$dist" && shasum -a 256 -c SHA256SUMS.txt)

scratch=$(mktemp -d "${TMPDIR:-/tmp}/alcove-release-key.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
printf '%s' "$signing_value" | /usr/bin/base64 -D > "$scratch/key"
unset signing_value
ALCOVE_EXPECTED_UPDATE_SIGNING_PUBLIC_KEY="$public_key" ./scripts/sign-update-manifest.sh \
    "$tag" "$commit" "$scratch/key" "$output" "$stem.dmg" "$stem.zip"
