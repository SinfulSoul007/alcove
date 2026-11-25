# Mozilla Readability

Vendored without modification from [mozilla/readability](https://github.com/mozilla/readability), release **0.6.0**, immutable commit **04fd32f72b448c12b02ba6c40928b67e510bac49** (release tag object b81a8d97bfd5c6cc6dc2ba7c88eca9e696e62354).

Readability.js SHA-256: `34dcab3d0832d0019f02990eed6b6124e029e8c32b9f0c6f2550544ff8dff174`.

Copyright (c) 2010 Arc90 Inc. Licensed under Apache License 2.0; retained upstream notice is in LICENSE.Readability.md and complete terms in LICENSE.Apache-2.0.txt. Readability.js retains its additional source copyright and attribution comments. Extract.js and Style.js are Alcove's separate extraction and presentation scripts, under the repository license.

Primary sources verified 2026-11-24: [release source](https://github.com/mozilla/readability/tree/04fd32f72b448c12b02ba6c40928b67e510bac49), [upstream usage/security guidance](https://github.com/mozilla/readability#security), and [CVE-2025-2792 advisory](https://github.com/mozilla/readability/security/advisories/GHSA-3p6v-hrg8-8qj7) (fixed in 0.6.0). Readability is an extractor, not a sanitizer. Alcove serializes an explicit structural allowlist, strips all original attributes except validated HTTP(S) hrefs, and renders in a separate script-disabled, network-denied WebView without extensions or native message handlers.

Updating: inspect upstream release/security notes, replace the exact source and retained license notices, record the immutable commit and SHA-256, then run `scripts/build.sh reader-extraction-test` and `scripts/build.sh reader-mode-test`. Never fetch extractor code at runtime.
