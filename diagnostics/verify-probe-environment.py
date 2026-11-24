#!/usr/bin/env python3
"""Exercise the real workflow watchdogs through SIP-protected system Perl."""
import argparse
from pathlib import Path
import os
import platform
import re
import subprocess
import tempfile

if platform.system() != "Darwin":
    raise SystemExit("This check requires macOS system Perl")

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--workflow", type=Path, default=Path(__file__).resolve().parents[1] / ".github/workflows/build-webkit.yml")
workflow = parser.parse_args().workflow
compatible_sdk = Path("/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk")
sdk = os.environ.get("ALCOVE_PROBE_SDK") or (
    str(compatible_sdk) if compatible_sdk.is_dir() else
    subprocess.check_output(["xcrun", "--show-sdk-path"], text=True).strip())
scripts = [code for code in re.findall(r"perl -e '([^']*)'", workflow.read_text())
           if "probe failed to launch" in code]
if len(scripts) != 4:
    raise SystemExit("Expected the actual privacy, menu, construction and runtime-error watchdogs")

with tempfile.TemporaryDirectory(prefix="alcove-watchdog-environment-") as scratch:
    root = Path(scratch)
    source, binary = root / "environment.c", root / "environment"
    source.write_text(r'''
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
int main(void) {
    const char *expected = getenv("ALCOVE_EXPECT_WEBKIT_ROOT");
    const char *names[] = {"DYLD_FRAMEWORK_PATH", "__XPC_DYLD_FRAMEWORK_PATH"};
    if (!expected || !*expected) return 2;
    for (unsigned i = 0; i < sizeof(names) / sizeof(names[0]); ++i) {
        const char *value = getenv(names[i]);
        if (!value || strcmp(value, expected)) {
            printf("FAIL: watchdog child lost %s\n", names[i]);
            return 1;
        }
    }
    puts("PASS: actual watchdog child retains both framework paths");
    return 0;
}
''')
    subprocess.run(["xcrun", "clang", "-Wall", "-Wextra", "-Werror",
                    "-isysroot", sdk, "-mmacosx-version-min=14.0", str(source), "-o", str(binary)], check=True)
    expected = str(root / "owned-frameworks")
    Path(expected).mkdir()
    environment = dict(os.environ, ALCOVE_EXPECT_WEBKIT_ROOT=expected,
                       DYLD_FRAMEWORK_PATH=expected, __XPC_DYLD_FRAMEWORK_PATH=expected)
    failures = 0
    for code in scripts:
        result = subprocess.run(["/usr/bin/perl", "-e", code, str(binary)], env=environment,
                                capture_output=True, text=True, timeout=10)
        print(result.stdout, end="")
        if result.returncode:
            failures += 1
            print("FAIL: workflow probe watchdog environment")
    if failures:
        raise SystemExit(1)
    print("PROBE_WATCHDOG_ENVIRONMENT_PROVEN true")
