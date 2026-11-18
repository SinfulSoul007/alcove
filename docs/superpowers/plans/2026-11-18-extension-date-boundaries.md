# Extension Date Boundary Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans for this task. Steps use checkbox syntax for tracking.

**Goal:** Preserve extension priority when recovering dates near Foundation's sentinels.

**Architecture:** Normalize only a cohort whose dates leave insufficient arithmetic headroom, preserving relative ordering and equal-date groups. Make new-date allocation normalize the catalog that will be saved at the same commit.

**Tech Stack:** Swift, encrypted Codable metadata, native installation SPI, Terminal Mac tests.

**Spec:** `docs/superpowers/specs/2026-11-18-extension-date-boundaries.md`

## Global Constraints

- Keep metadata format 8 and the existing optional installedAt field.
- Preserve identities, approvals, ordinary dates, relative order and equal-date ties.
- Use owned temporary data and the dedicated VM for complete fixtures.

## Review Focus

- Lower boundary with missing dates must repair once and remain idempotent.
- Upper boundary must never make a newly installed extension older.
- Equal dates must preserve their native extension-ID tie behavior.
- Invalid supplied clocks must not generate invalid dates.
- Updating an existing extension must not raise its priority.

### Task 1: Normalize only unsafe installation cohorts

**Files:** `Sources/BrowserCore/ExtensionCatalog.swift`, `Sources/Browser/ExtensionActions.swift`, `scripts/ExtensionCoreChecks.swift`, `scripts/ExtensionStoreChecks.swift`.

**Interfaces:** `nextInstallationDate(in:inout [BrowserExtensionRecord],now:Date) -> Date`; its mutated catalog and returned date are saved together.

- [x] Add lower-bound migration/idempotence, upper-bound actual install, tie preservation, ordinary-date preservation and invalid-clock regressions.
- [x] Run core/store fixtures in VM; observe the intended failures before implementation.
- [x] Extract date normalization from repaired. Rebase valid date groups to safe epoch offsets only if migration or allocation would cross a validity boundary. Keep invalid records in ordered legacy recovery.
- [x] Make new allocation normalize its inout catalog, sanitize the supplied clock, and persist the normalized catalog with the new record. Pending reviews use provisional dates; final commit determines priority.
- [x] Run core/store checks, validate native priority metadata through existing runtime checks, review the final diff and commit.

### Final verification

- [x] Request independent source review; fix material findings with regressions.
- [ ] Push the tested branch for full CI and integrate after required checks.
