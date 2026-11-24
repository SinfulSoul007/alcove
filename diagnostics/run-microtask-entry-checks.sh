#!/bin/bash
# Native regression qualification; all pages and data stores are disposable.
set -euo pipefail
[[ $# == 1 ]]
runtime=$(cd "$1" && pwd -P)
source_directory=$(cd "$(dirname "$0")" && pwd -P)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/alcove-promise-realms.XXXXXX")
fixture_server=''
cleanup() {
    if [[ -n "$fixture_server" ]]; then kill "$fixture_server" 2>/dev/null || true; wait "$fixture_server" 2>/dev/null || true; fi
    rm -rf "$scratch"
}
trap cleanup EXIT
sdk=$(xcrun --show-sdk-path)
if [[ -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]]; then sdk=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk; fi
xcrun swiftc -parse-as-library -warnings-as-errors -sdk "$sdk" -module-cache-path "$scratch/module-cache" "$source_directory/MicrotaskEntryChecks.swift" -o "$scratch/probe"
python3 "$source_directory/microtask-entry-server.py" "$scratch/port" > "$scratch/server.log" 2>&1 &
fixture_server=$!
for attempt in {1..1200}; do
    [[ -s "$scratch/port" ]] && break
    if ! kill -0 "$fixture_server" 2>/dev/null; then cat "$scratch/server.log"; exit 1; fi
    sleep 0.05
done
if [[ ! -s "$scratch/port" ]]; then cat "$scratch/server.log"; exit 1; fi
export ALCOVE_REALM_LOOPBACK="http://127.0.0.1:$(cat "$scratch/port")/"
export ALCOVE_EXPECT_WEBKIT_ROOT="$runtime" DYLD_FRAMEWORK_PATH="$runtime" __XPC_DYLD_FRAMEWORK_PATH="$runtime"
unset DYLD_INSERT_LIBRARIES __XPC_DYLD_INSERT_LIBRARIES
status=0
"$scratch/probe" > "$scratch/native.log" 2>&1 || status=$?
cat "$scratch/native.log"
[[ "$status" == 0 ]]
/usr/bin/grep -Fxq 'CROSS_REALM_PROMISE_CHECKS 26 FAILURES 0' "$scratch/native.log"
printf 'MICROTASK_ENTRY_NATIVE_QUALIFICATION_PASSED true\n'
