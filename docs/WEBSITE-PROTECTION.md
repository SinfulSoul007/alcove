# Local phishing catalog

The catalog uses PhishDestroy's curated Primary domains from the
[reviewed immutable source](https://github.com/phishdestroy/destroylist/tree/c22df68d2bded72fdb5415f929556dd220c8056c).
The bundled `Resources/WebsiteProtection/source.json` records the actual content
date, retrieval date, source revision, data and license hashes, and entry count.
The publisher's unmodified MIT notice accompanies the data.

The catalog classifies HTTP and HTTPS domains and their subdomains. An absent
match means unlisted. It does not classify page content, URL paths, IP addresses
or downloaded files. Its content date determines the thirty-day freshness limit.
Catalog updates initially ship in app releases.

At this development checkpoint, catalog validation and packaging are implemented;
the native navigation gate and visible warnings are still in progress.

## Maintainer refresh

Review an immutable commit of the publisher's Primary list, its content date and
license before updating. Keep the downloaded data and license byte-exact.
The offline command validates the complete replacement before changing the
existing catalog:

```sh
python3 scripts/refresh-website-protection.py \
  --domains /path/to/reviewed/list.txt \
  --license /path/to/reviewed/LICENSE \
  --revision FORTY_CHARACTER_COMMIT_SHA \
  --updated-at YYYY-MM-DDTHH:MM:SSZ \
  --retrieved-at YYYY-MM-DDTHH:MM:SSZ
```

Use the actual source content date and actual retrieval date. The default
destination is the repository's `Resources/WebsiteProtection`; `--destination`
supports an owned staging directory for review. Identical inputs produce
identical output. Empty, oversized, malformed and duplicate rows, invalid
provenance and changed licenses are refused. An existing destination containing
unrelated files is refused. An unexpected publisher license needs a fresh
licensing review before changing the approved license hash in the build validator.

```sh
python3 scripts/refresh-website-protection.py --verify Resources/WebsiteProtection
./scripts/build.sh website-protection-core-test
python3 scripts/WebsiteThreatResourceChecks.py
```

The build validates and copies the three resources beside manual test
executables and into `Alcove.app/Contents/Resources/WebsiteProtection` before
signing. The ZIP verifier checks the data, provenance and license; the full
preview verifier validates both the ZIP app and mounted DMG app against the
source resources. Run `./scripts/package.sh` and
`./scripts/verify-preview-package.sh` for the complete release checks.
