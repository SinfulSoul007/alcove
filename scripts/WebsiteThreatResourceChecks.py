"""Exercise maintainer refresh and packaged catalog rejection using owned files."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
ROWS = b"phishing.example\nxn--bcher-kva.example\r\n"
LICENSE = (ROOT / "Resources/WebsiteProtection/LICENSE.PhishDestroy.txt").read_bytes()
REVISION = "1234567890abcdef1234567890abcdef12345678"


class WebsiteThreatResourceChecks(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="alcove-catalog-check-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.rows = self.root / "input.txt"
        self.license = self.root / "license.txt"
        self.destination = self.root / "WebsiteProtection"
        self.rows.write_bytes(ROWS)
        self.license.write_bytes(LICENSE)

    def run_tool(self, *extra):
        return subprocess.run([
            sys.executable, str(ROOT / "scripts/refresh-website-protection.py"),
            "--domains", str(self.rows), "--license", str(self.license),
            "--revision", REVISION, "--updated-at", "2026-11-20T10:30:00Z",
            "--retrieved-at", "2026-11-21T12:00:00Z",
            "--destination", str(self.destination), *extra
        ], capture_output=True, text=True, timeout=15)

    def metadata(self):
        return {
            "formatVersion": 1, "provider": "PhishDestroy", "sourceRevision": REVISION,
            "sourceUpdatedAt": "2026-11-20T10:30:00Z", "retrievedAt": "2026-11-21T12:00:00Z",
            "sha256": hashlib.sha256(ROWS).hexdigest(),
            "licenseSHA256": hashlib.sha256(LICENSE).hexdigest(), "domainCount": 2
        }

    def test_refresh_preserves_source_and_license_and_records_actual_provenance(self):
        result = self.run_tool()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.destination / "domains.txt").read_bytes(), ROWS)
        self.assertEqual((self.destination / "LICENSE.PhishDestroy.txt").read_bytes(), LICENSE)
        self.assertEqual(json.loads((self.destination / "source.json").read_bytes()), self.metadata())
        first = {p.name: p.read_bytes() for p in self.destination.iterdir()}
        self.assertEqual(self.run_tool().returncode, 0)
        self.assertEqual({p.name: p.read_bytes() for p in self.destination.iterdir()}, first)

    def test_bad_refresh_cannot_modify_an_existing_catalog(self):
        self.assertEqual(self.run_tool().returncode, 0)
        original = {p.name: p.read_bytes() for p in self.destination.iterdir()}
        for rows in [b"", b"phishing.example\nphishing.example\n", b"PHISHING.example\n",
                     b"https://phishing.example/\n", b"phishing.example\n\n", b"127.0.0.1\n",
                     b"bad..example\n", b"\xff\n", b"a" * 8_388_609]:
            with self.subTest(rows=rows[:60]):
                self.rows.write_bytes(rows)
                result = self.run_tool()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Website protection:", result.stderr)
                self.assertEqual({p.name: p.read_bytes() for p in self.destination.iterdir()}, original)

    def test_unreviewed_license_and_invalid_provenance_are_refused(self):
        for extra in [("--revision", "main"), ("--updated-at", "yesterday"),
                      ("--updated-at", "2026-11-22T00:00:00Z")]:
            with self.subTest(extra=extra):
                result = self.run_tool(*extra)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Website protection:", result.stderr)
                self.assertFalse(self.destination.exists())
        self.license.write_bytes(b"A different license")
        result = self.run_tool()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Website protection:", result.stderr)
        self.assertFalse(self.destination.exists())

    def package(self, resources):
        path = self.root / "owned.zip"
        base = "Alcove.app/Contents/"
        with zipfile.ZipFile(path, "w") as archive:
            archive.writestr(base + "Info.plist", (ROOT / "scripts/Info.plist").read_bytes())
            binary = zipfile.ZipInfo(base + "MacOS/Alcove")
            binary.external_attr = 0o100755 << 16
            archive.writestr(binary, b"owned packaging fixture")
            archive.writestr(base + "Resources/Alcove.icns", b"owned icon fixture")
            archive.writestr(base + "Resources/LICENSE.txt", (ROOT / "LICENSE").read_bytes())
            for name, data in resources.items():
                archive.writestr(base + "Resources/WebsiteProtection/" + name, data)
        return subprocess.run([sys.executable, str(ROOT / "scripts/verify-package.py"), str(path)],
                              capture_output=True, text=True, timeout=15)

    def resources(self):
        return {"domains.txt": ROWS, "source.json": json.dumps(self.metadata()).encode(),
                "LICENSE.PhishDestroy.txt": LICENSE}

    def test_valid_package_keeps_all_existing_package_checks(self):
        result = self.package(self.resources())
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_missing_or_changed_packaged_catalog_cannot_pass(self):
        for name in self.resources():
            with self.subTest(missing=name):
                resources = self.resources()
                del resources[name]
                self.assertNotEqual(self.package(resources).returncode, 0)
        for name in self.resources():
            with self.subTest(edited=name):
                resources = self.resources()
                resources[name] += b"edited"
                self.assertNotEqual(self.package(resources).returncode, 0)

    def test_self_consistent_hash_does_not_allow_invalid_packaged_domains(self):
        resources = self.resources()
        resources["domains.txt"] = b"phishing.example\nphishing.example\n"
        metadata = self.metadata()
        metadata["sha256"] = hashlib.sha256(resources["domains.txt"]).hexdigest()
        resources["source.json"] = json.dumps(metadata).encode()
        self.assertNotEqual(self.package(resources).returncode, 0)

    def test_non_json_metadata_cannot_pass_packaging(self):
        resources = self.resources()
        resources["source.json"] = resources["source.json"][:-1] + b', "extra": NaN}'
        self.assertNotEqual(self.package(resources).returncode, 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
