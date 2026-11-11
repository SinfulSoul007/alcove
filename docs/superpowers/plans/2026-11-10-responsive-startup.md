# Responsive Protected-Data Startup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans inline. The user authorizes the existing main checkout, commits/pushes and same-identity unsigned builds; no further approval/mode gate.

**Goal:** Eliminate main-thread Keychain startup waits without losing saved profiles, tabs or pending links.

**Architecture:** Coalesce background key requests, keep weak lifecycle continuations, reuse the existing initial restore transaction, and gate normal UI until restore succeeds. Owner-scoped link queues drain after application restore preparation.

**Tech Stack:** Swift, AppKit, SwiftUI, Security, CryptoKit, existing manual checks.

**Spec:** `docs/superpowers/specs/2026-11-10-responsive-startup-design.md`

## Global Constraints
- macOS14; same Keychain service/account/access policy, encryption format and exact six entitlements.
- Version0.7.2/build14, candidate v0.7.2-preview.1; no public tag in this increment.
- Stable Visual Four identity; native launch/quit via Computer Use only. Private windows never wait for metadata.
- Existing explicitly injected synchronous fixtures remain supported; production defaults use background loading.

## Review Focus
- Closing/reopening several windows while a Security request never returns must not retain stores or multiply workers.
- Permission rejection, corrupt ciphertext, legacy migration failure and external file changes must not replace unreadable data.
- Restored Quick-only sessions and late restoration while a private window is foreground must preserve window ownership/focus.
- OS links arriving during startup/failure must use restored routing preferences once, with bounded queue and owner lifetime.
- Menus, keyboard shortcuts and mounted UI must not create default-profile WebKit storage before saved identity is known.

### Task 1: Make protected-data startup responsive and lifecycle-safe

**Files:** BrowserStore/Actions/AppDelegate/WindowOwner/UI, new MetadataKeyAccess and BrowserMetadataLoading; scripts/StartupChecks.swift and build.sh, Info.plist, goal verification/acceptance.

**Interfaces:** BrowserStore default initializes asynchronously; explicit keyProvider retains synchronous owned-fixture behavior. MetadataKeyAccess coalesces a background `(createIfMissing, allowInteraction)` request. Store exposes awaitingInitialMetadata and unlocking; initial completion callback prepares owner/windows and drains queued links. Owner dispatch can return pending while metadata is unknown.

- [x] Step1: Add owned blocking-key regression for the existing retry lifetime; run startup-test. Expected: closed store remains retained (FAIL), disk unchanged (PASS).
- [x] Step2: Extend regressions for responsive initial loading, off-main lookup, coalescing, close/reopen, error/retry, ciphertext preservation, private independence, normal profile/view gates, and queued routing. Implement service/restore/UI/window integration. Run startup-test and store-test sequentially. Expected: PASS, zero diagnostics.
- [x] Step3: Set version; run focused native/Quick checks and verify loading view through mounted native state plus live stable app when accessible. Expected: PASS, private/quit available, no premature named stores. Record native limitations honestly.
- [x] Step4: Commit; task-done with `caffeinate -is scripts/build.sh test`. Expected: complete suite PASS, zero compiler diagnostics. Reuse exact-source c499631/605080c baseline1463 rather than repeat baseline.
- [ ] Step5: Build optimized arm64/x86_64 sequentially and check signatures/runtime/min14/exact6 entitlements/Info. Expected: PASS.
- [ ] Step6: ONE fresh gpt-6-astra/high whole-plan review; regrade every finding and declined judgment. ONE Critical/Important RED→GREEN fix pass, then full suite/build gates. Defer minors; no second review.
- [ ] Step7: Push authorized main, wait for exact-source CI, verify download-back DMG/ZIP and hashes; deliver via thread outputs. Archive evidence then remove only this plan workspace. Full browser goal remains active.
