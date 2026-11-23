#!/usr/bin/env python3
"""Import a pinned research dependency baseline; never import its old WebKit."""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import tarfile
import tempfile
import unicodedata
import zipfile

OLD_WEBKIT = "WebKit.framework/Versions/A/WebKit"
RECEIPT = "AlcoveDependencyBaseline.json"
ZIP_NAMES = {"Alcove-WebKitRuntime.tar.gz", "AlcoveSource.txt", "WebKitSource.txt", "PatchChecksums.txt", "SHA256SUMS.txt"}
DEPENDENCY_ROOTS = {"JavaScriptCore.framework", "WebCore.framework", "WebGPU.framework", "WebKitLegacy.framework", "WebInspectorUI.framework", "libANGLE-shared.dylib", "libwebrtc.dylib", "ANGLEMetalLib.metallib", "PAL.swiftmodule"}
DEPENDENCY_SUBTREES = {"usr/local/include", "swift/bmalloc.swiftmodule"}
MAX_FILE = 512 * 1024 * 1024


def require(value, message):
    if not value:
        raise ValueError(message)


def digest_file(path, limit=MAX_FILE):
    require(path.is_file() and not path.is_symlink(), "Expected a regular input file")
    require(path.stat().st_size <= limit, "Input exceeds its size limit")
    digest = hashlib.sha256()
    size = 0
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            size += len(chunk)
            require(size <= limit, "Input exceeds its size limit")
            digest.update(chunk)
    return digest.hexdigest()


def json_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "Duplicate JSON field")
        result[key] = value
    return result


def load_json(path):
    require(path.is_file() and not path.is_symlink() and path.stat().st_size <= 65536, "Invalid JSON input")
    return json.loads(path.read_text(), object_pairs_hook=json_object,
                      parse_constant=lambda _: (_ for _ in ()).throw(ValueError("Invalid JSON constant")))


def relative_name(raw):
    require(isinstance(raw, str) and 0 < len(raw) <= 2048 and "\\" not in raw and "\0" not in raw, "Invalid archive path")
    path = PurePosixPath(raw)
    require(not path.is_absolute() and ".." not in path.parts and len(path.parts) <= 64, "Unsafe archive path")
    return str(path)


def excluded(name):
    return not (name.split("/", 1)[0] in DEPENDENCY_ROOTS or
                any(name == prefix or name.startswith(prefix + "/") for prefix in DEPENDENCY_SUBTREES))


def load_contract(path):
    contract = load_json(path)
    expected = {"formatVersion", "artifactID", "archiveSHA256", "runtimeSHA256", "wrapperCommit", "webkitRevision", "patches", "additionalPatch", "dependencyBinaries", "oldWebKitSHA256", "rebuiltProducts"}
    require(isinstance(contract, dict) and set(contract) == expected and contract["formatVersion"] == 1, "Invalid dependency contract")
    require(type(contract["artifactID"]) is int and contract["artifactID"] > 0, "Invalid artifact identity")
    for key in ["wrapperCommit", "webkitRevision"]:
        require(isinstance(contract[key], str) and re.fullmatch(r"[0-9a-f]{40}", contract[key]), "Invalid source revision")
    for key in ["archiveSHA256", "runtimeSHA256", "oldWebKitSHA256"]:
        require(isinstance(contract[key], str) and re.fullmatch(r"[0-9a-f]{64}", contract[key]), "Invalid archive digest")
    additional = contract["additionalPatch"]
    require(isinstance(additional, dict) and set(additional) == {"name", "sha256", "paths"}, "Invalid additional patch")
    paths = additional["paths"]
    require(isinstance(paths, list) and 0 < len(paths) <= 50 and len(set(paths)) == len(paths), "Invalid patch paths")
    require(all(relative_name(p).startswith("Source/WebKit/") for p in paths), "Additional patch must stay in WebKit")
    patches = contract["patches"]
    require(isinstance(patches, dict) and 0 < len(patches) <= 100 and additional["name"] not in patches, "Invalid baseline patch set")
    for name, digest in list(patches.items()) + [(additional["name"], additional["sha256"])]:
        require(isinstance(name, str) and re.fullmatch(r"[A-Za-z0-9_.-]+\.patch", name), "Invalid patch name")
        require(isinstance(digest, str) and re.fullmatch(r"[0-9a-f]{64}", digest), "Invalid patch digest")
    binaries = contract["dependencyBinaries"]
    require(isinstance(binaries, dict) and 0 < len(binaries) <= 20, "Missing dependency binaries")
    for name, digest in binaries.items():
        require(relative_name(name) == name and not excluded(name) and name != ".", "Invalid dependency path")
        require(isinstance(digest, str) and re.fullmatch(r"[0-9a-f]{64}", digest), "Invalid dependency digest")
    products = contract["rebuiltProducts"]
    require(isinstance(products, list) and 0 < len(products) <= 50 and len(set(products)) == len(products) and OLD_WEBKIT in products, "Invalid rebuilt products")
    require(all(relative_name(name) == name and name != "." and excluded(name) for name in products), "A rebuilt product overlaps cached dependencies")
    return contract


def verify_patches(directory, contract):
    additional = contract["additionalPatch"]
    expected = dict(contract["patches"], **{additional["name"]: additional["sha256"]})
    require({p.name for p in directory.glob("*.patch")} == set(expected), "Candidate patch set differs from the pinned baseline")
    for name, digest in expected.items():
        require(digest_file(directory / name, 1024 * 1024) == digest, "Candidate patch digest differs: " + name)
    text = (directory / additional["name"]).read_text()
    pairs = re.findall(r"^diff --git a/(\S+) b/(\S+)$", text, re.MULTILINE)
    require(pairs and all(a == b for a, b in pairs) and len({a for a, _ in pairs}) == len(pairs), "Unsupported additional patch paths")
    require({a for a, _ in pairs} == set(additional["paths"]), "Additional patch touches an unreviewed path")


def validate_members(archive):
    members = {}
    spellings = set()
    total = 0
    for index, member in enumerate(archive):
        require(index < 50000, "Too many archive entries")
        name = relative_name(member.name)
        require(0 <= member.size <= MAX_FILE, "Archive entry exceeds its size limit")
        total += member.size
        require(total <= 2 * 1024 * 1024 * 1024, "Archive exceeds its expanded size limit")
        if name == ".":
            require(member.isdir(), "Invalid archive root")
            continue
        spelling = unicodedata.normalize("NFC", name).casefold()
        require(spelling not in spellings, "Duplicate archive path")
        spellings.add(spelling)
        # Derived sources contain stale absolute build-machine pointers. None are imported.
        if excluded(name):
            continue
        require(member.type in {tarfile.REGTYPE, tarfile.AREGTYPE, tarfile.DIRTYPE, tarfile.SYMTYPE} and member.sparse is None, "Unsupported archive entry")
        if member.issym():
            target = relative_name(member.linkname)
            require(target != ".", "Invalid framework link")
        members[name] = member
    for name in members:
        for parent in PurePosixPath(name).parents:
            entry = members.get(str(parent))
            require(entry is None or entry.isdir(), "Archive writes through a non-directory entry")
    return members


def extract_dependencies(archive, members, destination):
    # Write data before links; all member/link paths forbid traversal and absolute targets.
    for name, member in members.items():
        path = destination / name
        if member.isdir():
            path.mkdir(parents=True, exist_ok=True)
        elif member.isfile():
            path.parent.mkdir(parents=True, exist_ok=True)
            with archive.extractfile(member) as source, path.open("xb") as output:
                shutil.copyfileobj(source, output, 1024 * 1024)
            path.chmod(member.mode & 0o777)
    for name, member in members.items():
        if member.issym():
            path = destination / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.symlink_to(member.linkname)


def verify_dependencies(destination, contract):
    root = destination.resolve(strict=True)
    for name, expected in contract["dependencyBinaries"].items():
        path = destination / name
        require(path.resolve(strict=True).is_relative_to(root), "Dependency resolves outside the build")
        require(digest_file(path) == expected, "Dependency binary differs: " + name)


def prepare(archive_path, destination, patches, contract):
    require(not destination.exists() and not destination.is_symlink(), "Destination already exists")
    verify_patches(patches, contract)
    require(digest_file(archive_path) == contract["archiveSHA256"], "Artifact digest differs")
    stage = None
    try:
        with zipfile.ZipFile(archive_path) as package, tempfile.TemporaryFile() as runtime:
            names = package.namelist()
            require(len(names) == len(ZIP_NAMES) and set(names) == ZIP_NAMES, "Unexpected or duplicate artifact entries")
            for info in package.infolist():
                limit = 256 * 1024 * 1024 if info.filename == "Alcove-WebKitRuntime.tar.gz" else 65536
                require(info.file_size <= limit, "Artifact entry exceeds its size limit")
            require(package.read("AlcoveSource.txt") == (contract["wrapperCommit"] + "\n").encode(), "Wrapper source differs")
            require(package.read("WebKitSource.txt") == (contract["webkitRevision"] + "\n").encode(), "WebKit source differs")
            rows = package.read("PatchChecksums.txt").decode().splitlines()
            pattern = r"([0-9a-f]{64})  diagnostics/([A-Za-z0-9_.-]+\.patch)"
            parsed = [re.fullmatch(pattern, row) for row in rows]
            require(all(parsed), "Invalid baseline patch metadata")
            recorded = {row[2]: row[1] for row in parsed}
            require(len(recorded) == len(rows) and recorded == contract["patches"], "Baseline patch metadata differs")
            expected_sum = contract["runtimeSHA256"] + "  Alcove-WebKitRuntime.tar.gz\n"
            require(package.read("SHA256SUMS.txt") == expected_sum.encode(), "Runtime checksum metadata differs")
            digest = hashlib.sha256()
            with package.open("Alcove-WebKitRuntime.tar.gz") as source:
                while chunk := source.read(1024 * 1024):
                    digest.update(chunk)
                    runtime.write(chunk)
            require(digest.hexdigest() == contract["runtimeSHA256"], "Runtime digest differs")
            runtime.seek(0)
            with tarfile.open(fileobj=runtime, mode="r:gz") as archive:
                members = validate_members(archive)
                old = next((m for m in archive.getmembers() if relative_name(m.name) == OLD_WEBKIT), None)
                require(old is not None and old.isfile(), "Baseline WebKit binary is missing")
                with archive.extractfile(old) as binary:
                    old_digest = hashlib.sha256()
                    while chunk := binary.read(1024 * 1024):
                        old_digest.update(chunk)
                    require(old_digest.hexdigest() == contract["oldWebKitSHA256"], "Baseline WebKit binary differs")
                destination.parent.mkdir(parents=True, exist_ok=True)
                stage = Path(tempfile.mkdtemp(prefix=".alcove-dependencies-", dir=destination.parent))
                extract_dependencies(archive, members, stage)
            verify_dependencies(stage, contract)
            require(not (stage / "WebKit.framework").exists() and not (stage / "DerivedSources").exists(), "Stale outputs remain")
            require(all(not (stage / name).exists() and not (stage / name).is_symlink() for name in contract["rebuiltProducts"]), "A WebKit project product was imported")
            (stage / RECEIPT).write_text(json.dumps({"formatVersion": 1, "contract": contract}, indent=2, sort_keys=True) + "\n")
            require(not destination.exists() and not destination.is_symlink(), "Destination already exists")
            os.rename(stage, destination)
            stage = None
    finally:
        if stage is not None:
            shutil.rmtree(stage)
    print("VERIFIED_DEPENDENCIES_PREPARED", len(contract["dependencyBinaries"]), contract["webkitRevision"])


def verify(destination, contract):
    receipt = load_json(destination / RECEIPT)
    require(receipt == {"formatVersion": 1, "contract": contract}, "Dependency receipt differs")
    verify_dependencies(destination, contract)
    for name in contract["rebuiltProducts"]:
        path = destination / name
        require(path.resolve(strict=True).is_relative_to(destination.resolve(strict=True)), "Rebuilt product resolves outside the build")
        require(path.is_file() and not path.is_symlink() and 0 < path.stat().st_size <= MAX_FILE, "A rebuilt project product is missing or invalid: " + name)
    current = digest_file(destination / OLD_WEBKIT)
    require(current != contract["oldWebKitSHA256"], "The baseline WebKit binary was not rebuilt")
    print("NEW_WEBKIT_AND_UNCHANGED_DEPENDENCIES_VERIFIED", current)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ["prepare", "verify"]:
        command = commands.add_parser(name)
        command.add_argument("--contract", type=Path, default=Path(__file__).with_name("webkit-dependency-baseline.json"))
        command.add_argument("--destination", type=Path, required=True)
        if name == "prepare":
            command.add_argument("--archive", type=Path, required=True)
            command.add_argument("--patch-directory", type=Path, required=True)
    args = parser.parse_args()
    try:
        contract = load_contract(args.contract)
        if args.command == "prepare":
            prepare(args.archive, args.destination, args.patch_directory, contract)
        else:
            verify(args.destination, contract)
    except (ValueError, OSError, tarfile.TarError, zipfile.BadZipFile) as error:
        parser.exit(1, "Dependency verification failed: " + str(error) + "\n")


if __name__ == "__main__":
    main()
