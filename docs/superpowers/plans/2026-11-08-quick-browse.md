# Quick Browse implementation plan

> Execute inline with superpowers:executing-plans, TDD and one fresh whole-branch review. Existing user authorization covers this checkout, commits/pushes and accurate previews; continue without approval check-ins.

**Goal:** Implement Arc's compact external-link workflow with real page handoff, profile-aware recovery and native windows.
**Architecture:** Profile-owned quick records share the existing BrowserStore/WebKit registry; one store owner leases primary/quick windows and retains a single writer.
**Tech Stack:** Swift/AppKit/SwiftUI/WebKit, macOS 14+, no external packages.
**Spec:** docs/superpowers/specs/2026-11-08-quick-browse-design.md

## Global Constraints
- Never introduce a second normal metadata writer or share persistent website stores across profiles.
- Keep macOS 14+, system WebKit, sandbox, encrypted metadata and private nonpersistence.
- Persist destructive ownership transitions before discarding/reparenting native pages; failed saves retain the old live state.
- Metadata format 3 uses the existing session-v2.sealed compatibility fork; unknown future formats refuse writes.
- Full Arc/native visual gates stay open; app access is still required to verify the latest UI.

## Review Focus
- A quick page's intended Space changes profiles or disappears while it navigates, opens Peek/popups or is promoted: the captured profile remains authoritative.
- Closing primary/quick windows in either order, including during promotion/clear/recovery, retains one store until its last lease ends.
- Saving fails before or after a navigation/close/profile transition; Unlock neither loses unsaved quick URLs nor resurrects closed quick records.
- Corrupt/old metadata reuses IDs across quick, live or Favorite records; normalization preserves content without sharing native views.
- Private windows, unavailable profiles, background media requests and stale callbacks cannot access another profile or normal persistent metadata.

### Task 1: Codable quick records, routing and normalization

**Files:** new Sources/BrowserCore/QuickBrowse.swift; modify Library.swift, Profiles.swift, Session.swift; new scripts/QuickBrowseCoreChecks.swift; build.sh.
**Produces:** QuickPage(tab:intendedSpaceID:openedAt:lastActiveAt:), QuickDomainChoice(host:profileID:), Preferences.quickBrowseExternalLinks/quickBrowseArchiveHours/quickDomainChoices, BrowserLibrary.quickPages, Tab.archiveSource, format-3 migration and repair; QuickBrowseRouting.profile(for:choices:available:fallback:), QuickBrowseRouting.host(for:), QuickBrowsePolicy.archiveCutoff(hours:now:).
- [x] Write failing behavioral checks for lossless format-2 migration/roundtrip; orphan quick owner; malformed identity collisions; exact-host routing/invalid URLs/unavailable destinations; inactivity cutoff and unknown future refusal. Run focused core executable; observe missing APIs and behavior failures.
- [x] Implement minimal models/routing/repair and duplicate-library merge with global live ID safety. Run focused checks and full suite; expected all pass.
- [x] Commit model/tests and ledger evidence.

### Task 2: Shared live pages and durable transitions

**Files:** new QuickBrowseStore.swift; modify BrowserStore.swift, BrowserProfiles.swift, BrowserActions.swift, PeekPanel.swift; new QuickBrowseStoreChecks.swift; extend real website fixture/checks; build.sh.
**Consumes:** Task 1 models; existing vault/profile registries/view map.
**Produces:** quickPages(for:), quickPage(_:), quickProfileID(_:), openQuickPage(url:profileID:intendedSpaceID:configuration:), navigateQuickPage(_:input:), closeQuickPage(_:), promoteQuickPage(_:to:allowProfileChange:), changeQuickProfile(_:to:rememberHost:allowReload:), restoreQuickArchive(_:profileID:), archiveInactiveQuickPages(now:), quickPagesDidChange callback, focusedQuickPageID and Peek source context.
- [x] Write RED checks for durable creation/reuse, owner lookup, profile reassignment, same-view promotion, consent/failure atomicity, archive/restore, private data, popup/Peek and clear/delete/recovery. Prove an actual fixture DOM/form survives promotion without a reload while cookie stores remain isolated.
- [x] Implement transactional normal/in-memory private candidates; route every view/event to its owner; keep quick pages alive during suspension; merge quick records correctly on Unlock. Guard stale callbacks and modal ownership. Extend profile clear/delete and auto-archive timer.
- [x] Run focused store/website checks and full suite; expected all pass. Commit and ledger evidence.

### Task 3: Native compact windows, ownership and release readiness

**Files:** new BrowserWindowOwner.swift, QuickBrowseUI.swift, QuickBrowseWindowController.swift, BrowserAppDelegate.swift; move top-level app delegate out of main.swift; modify LibraryUI.swift and settings/menus; new window-lifetime checks; README/SECURITY/acceptance/spec version docs.
**Consumes:** Task 2 APIs and callbacks.
**Produces:** single-writer window leases, external-link dispatch/reuse and opt-out, profile/domain selection with confirmation, same-view promotion, active quick keyboard/page actions, archive filtering and six-hour preference, accessible compact chrome.
- [x] Write RED lifetime/dispatch checks for closing/reopening primary, final quick close, promotion order, private owners and duplicate window leases; implement the real owner used by AppDelegate.
- [x] Build native controls around verified APIs and revalidate modal targets. Route external links through only the normal owner. Preserve first-run/update behavior. Test native UI when access permits; otherwise explicitly keep visual/keyboard/animation QA pending and continue independent checks.
- [ ] Run full suite and both optimized architecture builds; expected all software checks pass. Dispatch one fresh whole-branch reviewer with this Review Focus and ledger rulings. Re-grade findings by actual user effect and fix material findings with RED→GREEN, then full suite.
- [ ] Commit/push verified code. Package/publish a correctly labeled preview only after matching CI passes; verify downloaded-back artifacts/update offers. Leave the full browser goal active.
