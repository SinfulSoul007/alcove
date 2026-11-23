"""Build-time validation for the versioned, locally bundled phishing catalog."""
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re

LIMITS = {"domains.txt": 8_388_608, "source.json": 16_384, "LICENSE.PhishDestroy.txt": 65_536}
# A changed publisher license requires a fresh licensing review, not an automatic refresh.
APPROVED_LICENSE_SHA256 = "362a139d27061c725cdaad49d3ba2e61501cdfb33bcdf640c153aa259c8716f4"


def read_bounded(path, maximum):
    with Path(path).open("rb") as source:
        data = source.read(maximum + 1)
    if len(data) > maximum:
        raise ValueError("Catalog resource exceeds its size limit")
    return data


def domain_count(data):
    if not data or len(data) > LIMITS["domains.txt"]:
        raise ValueError("Domain data is empty or too large")
    rows = data.decode("utf-8").split("\n")
    if rows[-1] == "":
        rows.pop()
    if not 1 <= len(rows) <= 1_000_000:
        raise ValueError("Invalid domain count")
    seen = set()
    for row in rows:
        if row.endswith("\r"):
            row = row[:-1]
        labels = row.split(".")
        if (len(row) > 253 or len(labels) < 2 or
                not any("a" <= char <= "z" for char in labels[-1]) or
                any(re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?", label) is None for label in labels) or
                row in seen):
            raise ValueError("Malformed or duplicate domain; no rows were skipped")
        seen.add(row)
    return len(rows)


def source_date(value):
    if not isinstance(value, str) or re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z", value) is None:
        raise ValueError("Dates must use UTC YYYY-MM-DDTHH:MM:SSZ")
    date = datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    if date.timestamp() < 0:
        raise ValueError("Source date precedes the supported epoch")
    return date


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("Duplicate metadata field")
        result[key] = value
    return result


def reject_non_json_constant(value):
    raise ValueError("Non-JSON numeric constant in metadata: " + value)


def validate_catalog(domains, metadata, license_data):
    for name, data in [("domains.txt", domains), ("source.json", metadata),
                       ("LICENSE.PhishDestroy.txt", license_data)]:
        if not data or len(data) > LIMITS[name]:
            raise ValueError("Missing or oversized " + name)
    fields = json.loads(metadata, object_pairs_hook=unique_object, parse_constant=reject_non_json_constant)
    if (not isinstance(fields, dict) or type(fields.get("formatVersion")) is not int or
            fields["formatVersion"] != 1 or fields.get("provider") != "PhishDestroy" or
            type(fields.get("domainCount")) is not int or not 1 <= fields["domainCount"] <= 1_000_000):
        raise ValueError("Invalid catalog schema, provider or count")
    for key, size in [("sourceRevision", 40), ("sha256", 64), ("licenseSHA256", 64)]:
        value = fields.get(key)
        if not isinstance(value, str) or re.fullmatch(r"[a-f0-9]{%d}" % size, value) is None:
            raise ValueError("Invalid " + key)
    if source_date(fields.get("sourceUpdatedAt")) > source_date(fields.get("retrievedAt")):
        raise ValueError("Source content is newer than retrieval")
    if hashlib.sha256(domains).hexdigest() != fields["sha256"]:
        raise ValueError("Domain data checksum mismatch")
    license_digest = hashlib.sha256(license_data).hexdigest()
    if license_digest != fields["licenseSHA256"] or license_digest != APPROVED_LICENSE_SHA256:
        raise ValueError("Publisher license changed; review licensing before updating")
    if domain_count(domains) != fields["domainCount"]:
        raise ValueError("Domain count does not match metadata")
    return fields


def verify_directory(directory):
    root = Path(directory)
    data = {name: read_bounded(root / name, limit) for name, limit in LIMITS.items()}
    return validate_catalog(data["domains.txt"], data["source.json"], data["LICENSE.PhishDestroy.txt"])
