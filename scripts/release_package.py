"""Stage a verified installer archive from successful CI on this release commit."""

import hashlib
import json
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tempfile
from urllib.parse import urlencode
from zipfile import BadZipFile, ZipFile


ARTIFACT_NAME = "Alcove-universal-unsigned-preview"
CI_WORKFLOW = ".github/workflows/ci.yml"
CHECKSUMS = "SHA256SUMS.txt"
MAX_ARCHIVE_BYTES = 1024**3
FRESH_BUILD = 3


def positive_integer(value):
    return type(value) is int and value > 0


def eligible_run(run, repository, commit, version):
    owner = run.get("repository") or {}
    head = run.get("head_repository") or {}
    return (
        positive_integer(run.get("id"))
        and owner.get("full_name", "").lower() == repository.lower()
        and head.get("full_name", "").lower() == repository.lower()
        and positive_integer(owner.get("id"))
        and head.get("id") == owner["id"]
        and run.get("path") == CI_WORKFLOW
        and run.get("head_sha") == commit
        and run.get("head_branch") in ("main", f"preview/{version}")
        and run.get("event") == "push"
        and run.get("status") == "completed"
        and run.get("conclusion") == "success"
    )


def eligible_artifact(artifact, run):
    origin = artifact.get("workflow_run") or {}
    digest = artifact.get("digest")
    size = artifact.get("size_in_bytes")
    repository_id = run["repository"]["id"]
    return (
        artifact.get("name") == ARTIFACT_NAME
        and positive_integer(artifact.get("id"))
        and artifact.get("expired") is False
        and positive_integer(size)
        and size <= MAX_ARCHIVE_BYTES
        and isinstance(digest, str)
        and re.fullmatch(r"sha256:[a-f0-9]{64}", digest) is not None
        and origin.get("id") == run["id"]
        and origin.get("head_sha") == run["head_sha"]
        and origin.get("head_branch") == run["head_branch"]
        and origin.get("repository_id") == repository_id
        and origin.get("head_repository_id") == repository_id
    )


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for data in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(data)
    return digest.hexdigest()


def check_installers(directory, filenames):
    published = {}
    for line in (directory / CHECKSUMS).read_text(encoding="ascii").splitlines():
        match = re.fullmatch(r"([a-f0-9]{64})  (.+)", line)
        if match is None or match[2] not in filenames or match[2] in published:
            raise ValueError("Unexpected installer checksum entry")
        published[match[2]] = match[1]
    if published.keys() != filenames:
        raise ValueError("The artifact is missing installer checksums")
    for name, digest in published.items():
        if sha256(directory / name) != digest:
            raise ValueError(f"The artifact checksum disagrees with {name}")


def stage_artifact(source, artifact, version, destination):
    if destination.exists() or destination.is_symlink():
        raise ValueError("The release staging directory already exists")
    if source.stat().st_size != artifact["size_in_bytes"] or f"sha256:{sha256(source)}" != artifact["digest"]:
        raise ValueError("The downloaded archive disagrees with GitHub's artifact checksum or length")

    filenames = {f"Alcove-{version}-universal-unsigned-preview.{extension}" for extension in ("dmg", "zip")}
    with tempfile.TemporaryDirectory(prefix=".alcove-release-", dir=destination.parent) as temporary:
        staged = Path(temporary) / "dist"
        staged.mkdir()
        with ZipFile(source) as archive:
            members = archive.infolist()
            if len(members) != 3 or {item.filename for item in members} != filenames | {CHECKSUMS}:
                raise ValueError("The downloaded artifact must contain exactly the two installers and their checksums")
            for item in members:
                kind = stat.S_IFMT(item.external_attr >> 16)
                limit = 16 * 1024 if item.filename == CHECKSUMS else MAX_ARCHIVE_BYTES
                if kind not in (0, stat.S_IFREG) or not 0 < item.file_size <= limit:
                    raise ValueError("Unexpected file type or size in the artifact")
                with archive.open(item) as incoming, (staged / item.filename).open("xb") as output:
                    shutil.copyfileobj(incoming, output, length=1024 * 1024)
        check_installers(staged, filenames)
        staged.rename(destination)


def github_api(endpoint, **options):
    return subprocess.run(
        ["gh", "api", "--hostname", "github.com", endpoint],
        check=True, stderr=subprocess.PIPE, timeout=90, **options,
    )


def eligible_package(repository, commit, version):
    query = urlencode({"head_sha": commit, "event": "push", "status": "success", "per_page": 20})
    runs = json.loads(github_api(
        f"repos/{repository}/actions/workflows/ci.yml/runs?{query}", stdout=subprocess.PIPE,
    ).stdout)
    for run in runs["workflow_runs"]:
        if not eligible_run(run, repository, commit, version):
            continue
        artifacts = json.loads(github_api(
            f"repos/{repository}/actions/runs/{run['id']}/artifacts?" + urlencode({"name": ARTIFACT_NAME}),
            stdout=subprocess.PIPE,
        ).stdout)
        matches = [artifact for artifact in artifacts["artifacts"] if eligible_artifact(artifact, run)]
        if len(matches) == 1:
            return run["id"], matches[0]
    return None


def main(repository, commit, version, destination):
    if (not re.fullmatch(r"[a-zA-Z0-9-]+/[a-zA-Z0-9_.-]+", repository)
            or not re.fullmatch(r"[a-f0-9]{40}", commit)
            or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version)):
        raise ValueError("Expected the repository, tagged commit and installer version")
    with tempfile.TemporaryDirectory(prefix="alcove-ci-download-") as directory:
        source = Path(directory) / "artifact.zip"
        try:
            selection = eligible_package(repository, commit, version)
            if selection is None:
                print("No matching CI package is available. Build the tagged source.")
                return FRESH_BUILD
            run_id, artifact = selection
            with source.open("xb") as output:
                github_api(f"repos/{repository}/actions/artifacts/{artifact['id']}/zip", stdout=output)
        except (subprocess.SubprocessError, OSError, json.JSONDecodeError):
            print("Could not retrieve a CI package. Build the tagged source.")
            return FRESH_BUILD

        stage_artifact(source, artifact, version, Path(destination))
        print(f"Reused verified GitHub Actions run {run_id}, artifact {artifact['id']}.")
        return 0


if __name__ == "__main__":
    try:
        sys.exit(main(*sys.argv[1:]))
    except (ValueError, BadZipFile) as error:
        sys.exit(f"Cannot use the CI package: {error}")
