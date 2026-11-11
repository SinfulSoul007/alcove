# Safe Space Management Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans inline. Honor the user's existing main-checkout/autonomous execution preference, without another design/mode gate.

**Goal:** Provide safe, recoverable Space management and prevent cooperating Alcove processes from writing the same profile concurrently.

**Architecture:** A process-shared, cross-process exclusive metadata-directory lease protects normal writers. Encrypted per-profile deleted Space snapshots feed durable lifecycle operations and a responsive management sheet/sidebar actions.

**Tech Stack:** Swift, Darwin file locks, CryptoKit, AppKit, SwiftUI, WebKit, manual native/core checks.

**Spec:** `docs/superpowers/specs/2026-11-10-space-management-design.md`

## Global Constraints
- macOS14 and exact existing six entitlements; unchanged Keychain namespace/access/key policy.
- Metadata format4 with migration from1–3 and future rejection; no silent downgrade loss.
- Version0.8.0/build15, candidatev0.8.0-preview.1; stable Visual Four path/identity.
- No source changes during full checks; build/test shared caches sequentially. Exact-source remote CI can run concurrently on its separate Mac.
- Keep original full browser goal unfinished until every acceptance gate is proven. Reuse verified1494-check baseline at4bcef68/d58d2b1 instead of rerunning before RED.

## Review Focus
- Two independently launched processes, crash/shutdown, path aliases or symlink lock files must not produce simultaneous normal writers, unbounded waits or unnecessary Keychain requests.
- Rename/reorder/background deletion must preserve live website identity, account ownership, splits/Peeks, Favorites and unrelated metadata, including when persistence fails.
- Restore after relaunch/collisions/missing or pending profiles must not revive another account, duplicate global Favorites or silently retarget rules.
- Short/tiled windows, many Spaces, long names, large text, keyboard and drag/drop must keep manage/recovery controls usable.
- Old/future document formats, profile clear/delete and recovery merges must preserve or intentionally remove deleted snapshots without unnoticed downgrade loss.

### Task 1: Coordinate normal metadata ownership

**Files:** new Sources/BrowserCore/MetadataOwnership.swift; MetadataStore.swift; BrowserStore/MetadataLoading/Actions/MetadataStartupView; scripts/WriterOwnershipChecks.swift and build.sh.

**Interfaces:** MetadataOwnership.acquire(for:metadataURL) throws -> lease with idempotent release. Same canonical directory shares an OS descriptor/refcount within the process; other processes fail busy. BrowserStore owns lease before any normal key/read/write and releases after shutdown. MetadataStore.save obtains a cooperating temporary lease. Busy startup remains awaitingInitialMetadata with profileInUse state; retry reacquires first, private bypasses entirely.

- [x] Step1: Add self-spawning owned-key process regressions using current BrowserStore API. Run `caffeinate -is scripts/build.sh writer-test`. Expected: FAIL because secondary normal writer/key requests and direct saves currently succeed; process cleanup bounded.
- [x] Step2: Implement lease and startup/retry/shutdown integration, safe0600 O_NOFOLLOW/CLOEXEC regular lock file in0700 metadata directory, never unlink. Add alias/crash/private/symlink/release tests. Run writer-test then startup-test sequentially. Expected: PASS, zero diagnostics.
- [ ] Step3: Commit; task-done with `caffeinate -is scripts/build.sh test`. Expected: complete suite PASS, zero diagnostics. Keep source frozen through that run.

### Task 2: Build durable Space lifecycle and accessible controls

**Files:** new BrowserCore/SpaceManagement.swift, Browser/SpaceActions.swift and SpacesPanel.swift; BrowserCore Library/Profiles/BrowserCommand; Browser UI/Store/AppDelegate/CommandActions/Profiles; scripts/SpaceManagementChecks.swift, existing core format fixtures, build.sh, Info.plist and goal evidence.

**Interfaces:** profile-owned DeletedSpace snapshot with original index/date; optional BrowserLibrary.deletedSpaces. Store renameSpace/setSpaceIcon/moveSpace/deleteSpace/restoreDeletedSpace/permanentlyDeleteSpace use persist-before-publish. lastSpaceDeletion enables Undo. BrowserPanel.spaces, command palette/menu/footer/context/drop controls call these operations. Private commits remain ephemeral. Existing profile.clear removes deletedSpaces; merges preserve distinct snapshots.

- [ ] Step1: Add encrypted, owned-store regressions for rename/reorder/deletion/relaunch/recovery, Favorites/profile retention, last-Space fallback, ID collisions, routes, private isolation and failed saves. Update explicit format-version assertions to4/future5 while retaining legacy3 fixtures. Run space-test. Expected: missing lifecycle behavior FAIL before implementation.
- [ ] Step2: Implement model/migration/lifecycle operations and tests; run space-test and core/profile/store focused checks as needed. Expected: PASS, no key/website-store access from private operations or unavailable profiles, zero diagnostics.
- [ ] Step3: Add management sheet, quick/context/footer/command actions and sidebar reordering, safe confirmations and Undo. Add meaningful mounted short/large-text UI and action/lifetime checks; run space-test/sidebar-layout-test. Expected: controls bounded and operations preserve mounted website identity.
- [ ] Step4: Set0.8.0/build15; commit; task-done with `caffeinate -is scripts/build.sh test`. Expected: full suite PASS, zero diagnostics. Build optimized arm64/x86_64 sequentially and verify Info/signature/runtime/min14/exact6 entitlements.
- [ ] Step5: ONE fresh gpt-6-astra/high whole-plan review, regrade every finding/declined judgment; ONE Critical/Important RED→GREEN fix pass and full suite/build gates. No second review. Address directly related minors under the user's explicit remaining-issues request; leave unrelated older items separate.
- [ ] Step6: Push authorized main; inspect exact-source CI to terminal, verify downloaded universal artifact/DMG/hash contents. Update stable Visual Four only after CUA-confirmed quit and test real rename/reorder/delete/recover with owned temporary Spaces. Copy deliverables/evidence to thread outputs, record all rulings/costs and remaining scope; archive and remove only this plan workspace. Full goal remains active.
