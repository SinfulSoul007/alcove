#!/usr/bin/env python3
"""Validate pinned maintainer-supplied bytes; catalog updates ship with app releases."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile

from website_protection import LIMITS, domain_count, read_bounded, validate_catalog, verify_directory


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--verify", type=Path, help="Validate an existing resource directory without changing it")
    parser.add_argument("--domains", type=Path, help="Unmodified list.txt from a reviewed immutable Primary commit")
    parser.add_argument("--license", type=Path, help="Unmodified publisher license from that commit")
    parser.add_argument("--revision", help="Reviewed forty-character source commit")
    parser.add_argument("--updated-at", help="Actual source content date in UTC")
    parser.add_argument("--retrieved-at", help="Actual retrieval date in UTC")
    parser.add_argument("--destination", type=Path)
    args = parser.parse_args()
    try:
        if args.verify:
            if any([args.domains, args.license, args.revision, args.updated_at, args.retrieved_at, args.destination]):
                raise ValueError("Verification cannot be combined with refresh arguments")
            fields = verify_directory(args.verify)
        else:
            if not all([args.domains, args.license, args.revision, args.updated_at, args.retrieved_at]):
                raise ValueError("Refresh requires domains, license, revision, content date and retrieval date")
            domains = read_bounded(args.domains, LIMITS["domains.txt"])
            license_data = read_bounded(args.license, LIMITS["LICENSE.PhishDestroy.txt"])
            fields = {"formatVersion": 1, "provider": "PhishDestroy", "sourceRevision": args.revision,
                      "sourceUpdatedAt": args.updated_at, "retrievedAt": args.retrieved_at,
                      "sha256": hashlib.sha256(domains).hexdigest(),
                      "licenseSHA256": hashlib.sha256(license_data).hexdigest(), "domainCount": domain_count(domains)}
            metadata = (json.dumps(fields, indent=2) + "\n").encode()
            validate_catalog(domains, metadata, license_data)
            destination = args.destination or Path(__file__).resolve().parents[1] / "Resources/WebsiteProtection"
            if destination.is_symlink() or (destination.exists() and not destination.is_dir()):
                raise ValueError("Destination must be a real catalog directory")
            if destination.exists() and any(p.name not in LIMITS for p in destination.iterdir()):
                raise ValueError("Destination contains unrelated files")
            destination.parent.mkdir(parents=True, exist_ok=True)
            with tempfile.TemporaryDirectory(prefix=".website-catalog-", dir=destination.parent) as scratch:
                stage = Path(scratch) / "catalog"
                stage.mkdir()
                for name, data in [("domains.txt", domains), ("source.json", metadata),
                                   ("LICENSE.PhishDestroy.txt", license_data)]:
                    (stage / name).write_bytes(data)
                backup = Path(scratch) / "previous"
                if destination.exists():
                    os.replace(destination, backup)
                try:
                    os.replace(stage, destination)
                except OSError:
                    if backup.exists():
                        os.replace(backup, destination)
                    raise
        print("Verified PhishDestroy Primary catalog:", fields["domainCount"], "domains; source", fields["sourceRevision"])
        return 0
    except (OSError, ValueError) as error:
        print("Website protection:", error, file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
