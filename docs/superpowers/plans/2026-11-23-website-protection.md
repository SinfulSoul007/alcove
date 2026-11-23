# Local website protection implementation plan

> **For agentic workers:** Use superpowers:executing-plans inline. Preserve the isolated worktree and the full browser goal.

**Goal:** Add local phishing-domain classification and exact-request native warnings without uploading browsing addresses or bypassing existing page/extension ownership checks.

**Architecture:** A verified immutable BrowserCore catalog is loaded off the main actor by a shared app service. BrowserStore owns cancellable per-request policy tickets; a native page overlay resolves only its captured live ticket. Versioned data and its MIT license are packaged with the app.

**Tech Stack:** Swift, CryptoKit, AppKit, WebKit, Python maintainer tooling, existing manual/CI package scripts.

**Spec:** `docs/superpowers/specs/2026-11-23-website-protection-design.md`

## Global constraints

- Baseline app `c4c89fc13286649ed00781c50a38059410e4a1a5`; public 0.19.2 installers and native engine candidate 6666768 stay immutable.
- macOS 14+ system-WebKit app; no metadata-format or Keychain changes. No browsing-address service or persistent approval log.
- Use only the pinned curated PhishDestroy Primary source and include its MIT notice. No real threat-site requests. One QA app at most, closed after tests.
- New checks must not replay POST/body streams, frames or downloads as top-level GETs. Missing/corrupt data cannot silently advertise protection.

## Review Focus

- URL host ambiguity and shared-domain suffixes must not classify a lookalike as its listed neighbor; add literal core fixtures.
- Source failure or staleness must be visible and bounded, including private startup; add loader/unavailable-policy fixtures.
- Reentrant policy callbacks, redirects and multiple split-pane requests must resolve once for the correct page; add actual native loopback tests.
- Transfer/closure/profile clearing while the warning is visible must invalidate old buttons and pending decisions; add lifetime fixtures.
- Form, iframe and navigation-download continuation must preserve the native action and existing extension readiness; add target-server method/body/count assertions.

### Task 1: Verify and classify a bundled threat catalog

**Files:** Create `Sources/BrowserCore/WebsiteThreatCatalog.swift`, `scripts/WebsiteThreatCoreChecks.swift`, `Resources/WebsiteProtection/{domains.txt,source.json,LICENSE.PhishDestroy.txt}`, and `scripts/refresh-website-protection.py`. Modify `scripts/build.sh` and `scripts/verify-package.py` for resources/checks.

**Interfaces:** Produce `WebsiteThreatCatalog(domains: Data, metadata: Data) throws`, immutable `metadata`, `domainCount`, `threat(for: URL) -> WebsiteThreat?`, and `isStale(at: Date) -> Bool`. `WebsiteThreat` exposes canonical destination `host` and `listedHost`; metadata carries provider, source revision/date, SHA-256 and count. Constructor failures use `WebsiteThreatCatalogError`.

- [ ] Write literal core checks for listed/subdomain/lookalike, IDNA/encoded/root-dot/user-info cases, invalid catalogs, non-web/IP destinations and the exact 30-day freshness boundary. Run before implementation; expected missing-catalog API RED, not a fixture typo.
- [ ] Implement bounded validated parsing and canonical host classification. Run `./scripts/build.sh website-protection-core-test`; expected all behavioral checks pass.
- [ ] Bundle the byte-exact pinned source, license and provenance; add a maintainer command that validates new source and refuses an invalid replacement. Test its actual output, digest/count and bad-input refusal using owned fixture inputs; no source-text assertions.
- [ ] Copy resources into both app bundles and manual test executables, verify provenance/license during packaging, and add core checks to the existing full-test command. Verify actual pinned feed loading and independent sample membership without visiting threats. Commit.

### Task 2: Gate real requests and present native warnings

**Files:** Create focused service, navigation-ticket and native overlay files under `Sources/Browser/`, plus owned core/native/loopback fixtures under `scripts/`. Modify `BrowserStore.swift`, `BrowserActions.swift`, `BrowserUI.swift`, page teardown/transfer hooks, build test modes, documentation and security policy.

**Interfaces:** Consume Task 1 catalog. Service asynchronously returns listed/not-listed/unavailable plus freshness. Ticket captures a real WebKit decision and existing source lifetime, resolving it once; native overlay binds to that ticket. Exact helper names are settled after the native redirect characterization, without altering this contract.

- [ ] First characterize actual WebKit redirects with owned 127.0.0.1/localhost endpoints and record the action/response policy order. Write native RED fixtures proving a listed endpoint currently receives a request and no warning is shown.
- [ ] Implement asynchronous loading and exact-request tickets before the existing extension preparation/routing consumer; preserve original action semantics. Add cancellation to real lifecycle boundaries. Run owned request tests; expected blocked target count zero, original method/body/frame/download on explicit continuation, and no stale approvals.
- [ ] Implement the native page overlay with safe keyboard defaults and visible unavailable/stale state. Add actual control/lifetime/resize fixtures; test in the VM with an owned temporary metadata key, then quit the QA app.
- [ ] Run nearby extension-navigation, page-output/lifetime and multi-window suites, full exact-source hosted CI, and ZIP/mounted-DMG resource verification. One fresh whole-branch review, one material fix pass, record every remaining limitation. Integrate/publish only verified behavior; do not mark the full browser goal complete.
