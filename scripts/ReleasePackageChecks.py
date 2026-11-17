import hashlib
from pathlib import Path
import stat
import tempfile
import unittest
from unittest.mock import patch
from zipfile import ZipFile, ZipInfo

from release_package import FRESH_BUILD, eligible_artifact, eligible_run, main, stage_artifact


REPO = "SinfulSoul007/alcove"
REPOSITORY_ID = 1449823948
RUN_ID = 43988295201
SHA = "9cc61b692f42dee2ed0b08eee208d2cd5fa508b4"
VERSION = "0.14.0"
BRANCH = "preview/" + VERSION
NAME = "Alcove-universal-unsigned-preview"
DMG = f"Alcove-{VERSION}-universal-unsigned-preview.dmg"
ZIP = f"Alcove-{VERSION}-universal-unsigned-preview.zip"


def run(**patch):
    repository = {"id": REPOSITORY_ID, "full_name": REPO}
    return dict({
        "id": RUN_ID, "path": ".github/workflows/ci.yml", "head_sha": SHA, "head_branch": BRANCH,
        "repository": repository, "head_repository": repository,
        "event": "push", "status": "completed", "conclusion": "success",
    }, **patch)


def artifact(**patch):
    return dict({
        "name": NAME, "id": 14289249066, "digest": "sha256:" + "a" * 64, "size_in_bytes": 500,
        "expired": False, "workflow_run": {
            "id": RUN_ID, "head_sha": SHA, "head_branch": BRANCH,
            "repository_id": REPOSITORY_ID, "head_repository_id": REPOSITORY_ID,
        },
    }, **patch)


class ReleasePackageChecks(unittest.TestCase):
    def test_only_exact_successful_push_builds_are_eligible(self):
        self.assertTrue(eligible_run(run(), REPO, SHA, VERSION))
        self.assertTrue(eligible_run(run(head_branch="main"), REPO, SHA, VERSION))
        for patch in (
            {"head_sha": "a" * 40},
            {"event": "pull_request"},
            {"event": "workflow_dispatch"},
            {"conclusion": "failure"},
            {"status": "in_progress"},
            {"path": ".github/workflows/unrelated.yml"},
            {"head_branch": "preview/0.15.0"},
            {"head_branch": "feat/unreviewed"},
            {"head_repository": {"id": 3701, "full_name": "someone/alcove"}},
        ):
            with self.subTest(patch=patch):
                self.assertFalse(eligible_run(run(**patch), REPO, SHA, VERSION))

    def test_only_live_artifact_from_the_selected_run_is_eligible(self):
        self.assertTrue(eligible_artifact(artifact(), run()))
        for patch in (
            {"name": "extension-cache"},
            {"expired": True},
            {"digest": None},
            {"digest": "sha256:broken"},
            {"size_in_bytes": 0},
            {"workflow_run": dict(artifact()["workflow_run"], id=200)},
            {"workflow_run": dict(artifact()["workflow_run"], head_branch="main")},
            {"workflow_run": dict(artifact()["workflow_run"], head_sha="d" * 40)},
            {"workflow_run": dict(artifact()["workflow_run"], head_repository_id=99)},
        ):
            with self.subTest(patch=patch):
                self.assertFalse(eligible_artifact(artifact(**patch), run()))

    def stage(self, entries, *, corrupt=False, wrong_size=False, incorrect_inner=False, allowed=True):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            files = {ZIP: b"zip fixture", DMG: b"dmg fixture"}
            sums = "".join(f"{hashlib.sha256(data).hexdigest()}  {name}\n" for name, data in files.items())
            if incorrect_inner:
                sums = "0" * 64 + sums[64:]
            files["SHA256SUMS.txt"] = sums.encode()
            outer = root / "artifact.zip"
            with ZipFile(outer, "w") as archive:
                for name, body in (entries or list(files.items())):
                    archive.writestr(name, body)
            checksum = hashlib.sha256(outer.read_bytes()).hexdigest()
            description = artifact(digest="sha256:" + ("0" * 64 if corrupt else checksum),
                                   size_in_bytes=outer.stat().st_size + int(wrong_size))
            destination = root / "dist"
            if allowed:
                stage_artifact(outer, description, VERSION, destination)
                self.assertEqual({path.name for path in destination.iterdir()}, set(files))
                for name, body in files.items():
                    self.assertEqual((destination / name).read_bytes(), body)
            else:
                with self.assertRaises(ValueError):
                    stage_artifact(outer, description, VERSION, destination)
                self.assertFalse(destination.exists())

    def test_exact_installers_are_staged_unchanged(self):
        self.stage(None)

    def test_outer_length_digest_and_inner_checksums_are_required(self):
        self.stage(None, corrupt=True, allowed=False)
        self.stage(None, wrong_size=True, allowed=False)
        self.stage(None, incorrect_inner=True, allowed=False)

    def test_incomplete_or_unexpected_members_are_rejected(self):
        self.stage([(ZIP, b"a"), (DMG, b"b")], allowed=False)
        self.stage([(ZIP, b"a"), (DMG, b"b"), ("SHA256SUMS.txt", b"c"), ("other", b"d")], allowed=False)

    def test_archive_symlinks_are_rejected(self):
        symlink = ZipInfo(DMG)
        symlink.create_system = 3
        symlink.external_attr = (stat.S_IFLNK | 0o777) << 16
        self.stage([(ZIP, b"a"), (symlink, b"unused"), ("SHA256SUMS.txt", b"c")], allowed=False)

    def test_unavailable_package_requests_a_clean_build(self):
        with tempfile.TemporaryDirectory() as root:
            destination = Path(root) / "dist"
            with patch("release_package.eligible_package", return_value=None):
                self.assertEqual(main(REPO, SHA, VERSION, destination), FRESH_BUILD)
            self.assertFalse(destination.exists())


if __name__ == "__main__":
    unittest.main()
