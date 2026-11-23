#!/usr/bin/env python3
"""Exercise the real dependency-import CLI using owned ZIP/tar inputs."""
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import shutil
import sys
import tarfile
import tempfile
import unittest
import zipfile

HELPER = Path(__file__).with_name("prepare-webkit-dependencies.py")
OLD = "WebKit.framework/Versions/A/WebKit"
CORE = "WebCore.framework/Versions/A/WebCore"
PATCH = b"diff --git a/Source/WebKit/Owned.h b/Source/WebKit/Owned.h\n--- a/Source/WebKit/Owned.h\n+++ b/Source/WebKit/Owned.h\n@@ -1 +1 @@\n-old\n+new\n"


def sha(data):
    return hashlib.sha256(data).hexdigest()


class DependencyChecks(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="alcove-dependency-check-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.patches = self.root / "patches"
        self.patches.mkdir()
        (self.patches / "prior.patch").write_bytes(b"immutable prior patch\n")
        (self.patches / "new.patch").write_bytes(PATCH)
        self.entries = [
            (CORE, b"#!/bin/sh\nexit 0\n", "file"),
            ("WebCore.framework/Versions/Current", "A", "symlink"),
            ("WebCore.framework/WebCore", "Versions/Current/WebCore", "symlink"),
            (OLD, b"old framework", "file"),
            ("DerivedSources/WebCore/old.h", b"stale generated header", "file"),
            ("DerivedSources/WebCore/build-machine", "/outside/the/cache", "symlink"),
        ]
        self.contract = {
            "formatVersion": 1, "artifactID": 17,
            "wrapperCommit": "1" * 40, "webkitRevision": "2" * 40,
            "patches": {"prior.patch": sha(b"immutable prior patch\n")},
            "additionalPatch": {"name": "new.patch", "sha256": sha(PATCH), "paths": ["Source/WebKit/Owned.h"]},
            "dependencyBinaries": {CORE: sha(b"#!/bin/sh\nexit 0\n")},
            "oldWebKitSHA256": sha(b"old framework"),
            "rebuiltProducts": [OLD, "com.apple.WebKit.WebContent.xpc/Contents/MacOS/XPCService"],
        }
        self.archive = self.root / "baseline.zip"
        self.contract_path = self.root / "contract.json"
        self.write_archive()
        self.control = self.root / "control"
        result = self.prepare(self.control)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.control / CORE).read_bytes(), b"#!/bin/sh\nexit 0\n")

    def write_archive(self, metadata=None, duplicates=False):
        data = io.BytesIO()
        with tarfile.open(fileobj=data, mode="w:gz") as archive:
            for name, content, kind in self.entries:
                member = tarfile.TarInfo(name)
                member.mode = 0o755 if name == CORE else 0o644
                if kind == "symlink":
                    member.type = tarfile.SYMTYPE
                    member.linkname = content
                    archive.addfile(member)
                elif kind == "hardlink":
                    member.type = tarfile.LNKTYPE
                    member.linkname = content
                    archive.addfile(member)
                else:
                    member.size = len(content)
                    archive.addfile(member, io.BytesIO(content))
        runtime = data.getvalue()
        self.contract["runtimeSHA256"] = sha(runtime)
        payload = {
            "Alcove-WebKitRuntime.tar.gz": runtime,
            "AlcoveSource.txt": (self.contract["wrapperCommit"] + "\n").encode(),
            "WebKitSource.txt": (self.contract["webkitRevision"] + "\n").encode(),
            "PatchChecksums.txt": (sha(b"immutable prior patch\n") + "  diagnostics/prior.patch\n").encode(),
            "SHA256SUMS.txt": (sha(runtime) + "  Alcove-WebKitRuntime.tar.gz\n").encode(),
        }
        payload.update(metadata or {})
        with zipfile.ZipFile(self.archive, "w") as archive:
            for name, content in payload.items():
                archive.writestr(name, content)
            if duplicates:
                import warnings
                with warnings.catch_warnings():
                    warnings.simplefilter("ignore", UserWarning)
                    archive.writestr("WebKitSource.txt", payload["WebKitSource.txt"])
        self.contract["archiveSHA256"] = sha(self.archive.read_bytes())
        self.contract_path.write_text(json.dumps(self.contract))

    def run_cli(self, *args):
        return subprocess.run([sys.executable, str(HELPER), *args, "--contract", str(self.contract_path)], capture_output=True, text=True, timeout=20)

    def prepare(self, destination):
        return self.run_cli("prepare", "--archive", str(self.archive), "--destination", str(destination), "--patch-directory", str(self.patches))

    def refused(self):
        destination = self.root / "refused"
        result = self.prepare(destination)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertFalse(destination.exists())
        self.assertEqual(list(self.root.glob(".alcove-dependencies-*")), [])

    def test_import_keeps_working_binary_and_framework_links_but_drops_stale_outputs(self):
        self.assertEqual(subprocess.run([str(self.control / "WebCore.framework/WebCore")]).returncode, 0)
        self.assertTrue((self.control / "WebCore.framework/Versions/Current").is_symlink())
        self.assertFalse((self.control / "WebKit.framework").exists())
        self.assertFalse((self.control / "DerivedSources").exists())
        receipt = json.loads((self.control / "AlcoveDependencyBaseline.json").read_text())
        self.assertEqual(receipt["contract"], self.contract)

    def test_edited_outer_archive_and_inner_hash_are_refused(self):
        with self.archive.open("ab") as stream:
            stream.write(b"edited")
        self.refused()
        self.write_archive()
        self.contract["runtimeSHA256"] = "0" * 64
        self.contract_path.write_text(json.dumps(self.contract))
        self.refused()

    def test_mismatched_source_provenance_and_duplicate_zip_entries_are_refused(self):
        self.write_archive({"WebKitSource.txt": b"3" * 40 + b"\n"})
        self.refused()
        self.write_archive(duplicates=True)
        self.refused()

    def test_current_patches_must_match_and_new_patch_stays_in_webkit(self):
        (self.patches / "prior.patch").write_bytes(b"changed")
        self.refused()
        (self.patches / "prior.patch").write_bytes(b"immutable prior patch\n")
        changed = PATCH.replace(b"Source/WebKit/", b"Source/WebCore/")
        (self.patches / "new.patch").write_bytes(changed)
        self.contract["additionalPatch"]["sha256"] = sha(changed)
        self.contract_path.write_text(json.dumps(self.contract))
        self.refused()

    def test_unsafe_tar_paths_links_and_duplicate_names_are_refused_without_partial_output(self):
        original = list(self.entries)
        for extra in [
            ("../escaped", b"escape", "file"),
            ("WebCore.framework/outside", "/tmp/escaped", "symlink"),
            ("WebCore.framework/outside", "../escaped", "symlink"),
            ("WebCore.framework/hard", CORE, "hardlink"),
            ("./" + CORE, b"duplicate", "file"),
            ("WebCore.framework/WebCore/child", b"through link", "file"),
        ]:
            with self.subTest(entry=extra[0]):
                self.entries = original + [extra]
                self.write_archive()
                self.refused()
        self.assertFalse((self.root / "escaped").exists())

    def test_existing_destination_is_never_replaced(self):
        marker = self.control / "owned-marker"
        marker.write_text("keep me")
        self.assertNotEqual(self.prepare(self.control).returncode, 0)
        self.assertEqual(marker.read_text(), "keep me")
        self.assertEqual((self.control / CORE).read_bytes(), b"#!/bin/sh\nexit 0\n")

    def test_webkit_owned_services_overlays_and_tools_are_never_imported(self):
        stale = ["com.apple.WebKit.WebContent.xpc/Contents/MacOS/XPCService", "libWebKitSwift.dylib", "libWebKitSwift.tbd", "WebKitSwift.swiftmodule/arm64.swiftmodule", "_WebKit_SwiftUI.framework/old", "webpushd", "webpushtool", "adattributiond", "WebKitTestSupport/old.h", "swift/WebKit.swiftcrossimport/SwiftUI.swiftoverlay"]
        self.entries += [(name, b"stale project product", "file") for name in stale]
        self.entries += [("usr/local/include/wtf/Owned.h", b"cached dependency header", "file"), ("swift/bmalloc.swiftmodule/arm64.swiftmodule", b"cached allocator module", "file")]
        self.write_archive()
        destination = self.root / "project-products"
        result = self.prepare(destination)
        self.assertEqual(result.returncode, 0, result.stderr)
        for name in stale:
            self.assertFalse((destination / name).exists(), name)
        self.assertEqual((destination / "usr/local/include/wtf/Owned.h").read_bytes(), b"cached dependency header")
        self.assertEqual((destination / "swift/bmalloc.swiftmodule/arm64.swiftmodule").read_bytes(), b"cached allocator module")

    def test_postbuild_requires_new_webkit_and_exact_unchanged_dependencies(self):
        def verify():
            return self.run_cli("verify", "--destination", str(self.control))
        self.assertNotEqual(verify().returncode, 0)
        binary = self.control / OLD
        binary.parent.mkdir(parents=True)
        binary.write_bytes(b"old framework")
        self.assertNotEqual(verify().returncode, 0)
        binary.write_bytes(b"new framework")
        self.assertNotEqual(verify().returncode, 0)
        service = self.control / "com.apple.WebKit.WebContent.xpc/Contents/MacOS/XPCService"
        service.parent.mkdir(parents=True)
        service.write_bytes(b"new service executable")
        self.assertEqual(verify().returncode, 0)
        (self.control / CORE).write_bytes(b"edited dependency")
        self.assertNotEqual(verify().returncode, 0)


class LauncherChecks(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="alcove-project-launcher-")
        self.addCleanup(self.temporary.cleanup)
        self.root = (Path(self.temporary.name) / "source with spaces").resolve()
        scripts = self.root / "Tools/Scripts"
        scripts.mkdir(parents=True)
        (self.root / "Source/WebKit/WebKit.xcodeproj").mkdir(parents=True)
        self.launcher = scripts / "build-alcove-webkit-project"
        source = Path(__file__).with_name("build-webkit-project-only.pl")
        if source.exists():
            shutil.copyfile(source, self.launcher)
        (scripts / "webkitdirs.pm").write_text('''package webkitdirs;
use strict;use warnings;
sub sourceDir {return $ENV{'OWNED_SOURCE_ROOT'};}
sub XcodeOptions {
 die 'workspace was not suppressed' unless @ARGV == 1 && $ARGV[0] eq '--no-use-workspace';
 @ARGV=();
 return ('-configuration','Release','GCC_OPTIMIZATION_LEVEL=1','WK_LTO_MODE=none',
  'SYMROOT='.$ENV{'OWNED_SOURCE_ROOT'}.'/WebKitBuild','SDKROOT=macosx');
}
1;
''')
        binary_dir = self.root / "owned-bin"
        binary_dir.mkdir()
        compiler = binary_dir / "xcodebuild"
        compiler.write_text("#!" + sys.executable + '''
import json,os,sys
from pathlib import Path
with Path(os.environ['COMMAND_CAPTURE']).open('a') as out:
 out.write(json.dumps({'arguments':sys.argv[1:],'cwd':os.getcwd()})+'\\n')
print('OWNED_COMPILER_INVOKED')
sys.exit(int(os.environ.get('COMPILER_STATUS','0')))
''')
        compiler.chmod(0o755)
        self.capture = self.root / "commands.jsonl"
        self.environment = dict(os.environ, PATH=str(binary_dir) + os.pathsep + os.environ['PATH'], OWNED_SOURCE_ROOT=str(self.root), COMMAND_CAPTURE=str(self.capture))

    def run_launcher(self, *arguments, status=0):
        return subprocess.run(['/usr/bin/perl', str(self.launcher), *arguments], cwd=self.root.parent,
                              env=dict(self.environment, COMPILER_STATUS=str(status)), capture_output=True, text=True, timeout=20)

    def test_single_project_aggregate_uses_the_upstream_flags_without_a_second_build(self):
        result = self.run_launcher()
        self.assertEqual(result.returncode, 0, result.stderr)
        commands = [json.loads(row) for row in self.capture.read_text().splitlines()]
        self.assertEqual(len(commands), 1)
        self.assertEqual(commands[0], {'arguments': ['-project', str(self.root / 'Source/WebKit/WebKit.xcodeproj'), '-target', 'Everything', '-configuration', 'Release', 'GCC_OPTIMIZATION_LEVEL=1', 'WK_LTO_MODE=none', 'SYMROOT=' + str(self.root / 'WebKitBuild'), 'SDKROOT=macosx', 'GCC_GENERATE_DEBUGGING_SYMBOLS=NO', 'COMPILER_INDEX_STORE_ENABLE=NO'], 'cwd': str(self.root)})

    def test_compiler_failure_is_the_launcher_failure(self):
        self.assertEqual(self.run_launcher(status=23).returncode, 23)

    def test_extra_project_arguments_are_refused_before_any_compiler_runs(self):
        self.assertNotEqual(self.run_launcher('-project', 'other.xcodeproj').returncode, 0)
        self.assertFalse(self.capture.exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
