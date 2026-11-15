# Shared Browser Windows Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking. Native inline execution is selected under the user's standing autonomous authorization; one fresh final whole-implementation review after verification.

**Goal:** Multiple normal windows with shared tab organization, independent controls and state-preserving live tab handoff.

**Architecture:** BrowserWindowWorkspace projects canonical session data through window selections. A main-actor group coordinates existing BrowserStore lenses, one metadata writer and unique live page resources. Native window/menu and extension adapters use explicit per-window ownership.

**Tech Stack:** Swift, Foundation, Combine, AppKit, SwiftUI, WebKit, CryptoKit; existing manual checks and dedicated VM.

**Spec:** docs/superpowers/specs/2026-11-15-shared-windows-design.md

## Global Constraints
- macOS14.0 minimum; existing six entitlements, protected Keychain/encrypted storage and profile/private boundaries.
- One normal data writer; no copied/reloaded documents to simulate handoff.
- Work in existing isolated VM linked worktree feat/shared-windows at c6210cc. Public0.9.1/tag/assets and canonical main remain independent.
- Feature preview0.10.0/build18 and encrypted format6 migration only after implementation gates; no full-browser completion claim.

## Review Focus
- Two windows select different tabs/Spaces while either window edits shared organization, including tab/Space/profile removal during an async source-bound request.
- Same-tab handoff preserves the exact WKWebView/document/unsaved form and cannot bounce back during an old window's redraw.
- Closing a window, including the original root window, preserves remaining windows, Quick/private state and the single writer; closed-window callbacks cannot mutate or steal focus.
- Extension normal-window registration/identity and source-bound actions remain distinct from private-client authorization; profile clearing/host retirement reaches every page once.
- Restore/migration and old-window records cannot overwrite newer edits, recreate closed tabs or leave an offscreen/unreachable window.

### Task1: Window session/assignment model

**Files:** Create Sources/BrowserCore/BrowserWindowWorkspace.swift and scripts/BrowserWindowWorkspaceChecks.swift; add explicit window-model-test mode in scripts/build.sh.

**Interfaces:** BrowserWindowSelection: Codable/Equatable with id, spaceID and selectedTabsBySpace; capture init(id:session:). BrowserWindowWorkspace.init(session:windows:focusedWindowID:assignments:) throws; private(set) session/windows/focusedWindowID/assignments; session(for:) -> Session?; openWindow(id:copying:) throws -> BrowserWindowSelection; apply(_:from:) throws; focusWindow(_:) -> Bool; closeWindow(_:) -> Bool; claim(_:for:) -> Bool; assignedWindow(for:) -> UUID?. BrowserWindowWorkspaceError: missingWindow, duplicateWindow, invalidSession. No AppKit/Keychain/file/network side effects.

- [x] Step1: Write checks for two independent selections, live shared URL/folder/order changes, focus projection, new-tab assignment, explicit claim, close reassignment, deleted Space/tab repair, missing/duplicate IDs and input value preservation.
- [x] Step2: Run explicit mode against unchanged core. Expect only the new model API missing-symbol compile failures, not fixture errors; save RED evidence.
- [x] Step3: Implement selection capture/projection/reconciliation and serialized shared-session updates. Focused selection sets legacy canonical selection. Duplicate global Space/tab IDs are rejected before dictionary construction; empty sessions repair as existing browser behavior. New tabs belong to the editing window; close reassigns existing tab identities to a survivor. Never rewrite tab content to implement selection.
- [x] Step4: Run focused checks and existing core checks; require all pass without diagnostics. Commit this foundation on the isolated feature branch with remaining integration explicitly pending.

### Task2: One data writer and window-local store lenses

**Files:** Create Sources/Browser/BrowserWindowGroup.swift; modify BrowserStore.swift, BrowserWindowOwner.swift, BrowserProfiles.swift, BrowserActions.swift, QuickBrowseStore.swift, BrowserMetadataLoading.swift, MetadataStartupView.swift, and relevant profile/Space/Boost shared transactions; add scripts/BrowserWindowGroupChecks.swift.

**Interfaces:** BrowserWindowGroup(root:) retains root only through existing owner; makePrimaryStore(copying:) -> BrowserStore; publishSession(_:from:), publishDocument(_:from:), flush(from:), register/unregister primary member and focused member; members weakly registered. BrowserStore initializer for a secondary group member skips normal metadata startup/lease acquisition and delegates shared writes/state to root. Save/document application uses current group snapshot and broadcasts in one guarded main-actor transaction.

- [ ] Step1: Add failing owned-root/secondary tests proving one lease/key lookup/writer; independent selection/chrome; shared edits and async stale-writer refusal; root-window retirement and save-failure propagation. Include tab/Space/profile removal and Quick state while secondary survives.
- [ ] Step2: Implement group binding and transaction routing, preserving private-store isolation and current single-store tests. Run focused group, metadata/startup/profile/Space/Quick checks without diagnostics.

### Task3: Live resource/presentation handoff and durable restoration

**Files:** Create Sources/Browser/BrowserWindowPages.swift; modify BrowserUI.swift, BrowserStore.swift, BrowserActions.swift, BrowserProfiles.swift, PeekPanel.swift, BoostRuntime.swift, profile/extension erasure paths, BrowserCore/MetadataStore.swift, BrowserCore/Profiles.swift and their existing check fixtures. Add scripts/BrowserWindowHandoffChecks.swift with owned WebKit documents.

**Interfaces:** Group claimPresentation(tabID:in:), presentation(tabID:in:) -> owned/elsewhere/unavailable; transfer resource ownership without discard; document identity explicitly transferred; close-member/page/profile and protected-display-ID aggregation. Rendering consults presentation and cannot claim. Explicit selection/Bring it here claims; Go to window only surfaces the presenter. Window restore records encode selections, assignments and finite geometry in format6; old format5 migrates with unchanged data.

- [ ] Step1: Write failing actual-WebKit checks using post-load unsaved form, per-request token, scroll and media state; claim both directions, old-root redraw and independent second tab; close/root/private/profile/output/Boost stale-callback cases. Assert no additional navigation and exactly one view per tab across the group.
- [ ] Step2: Implement the transfer and themed placeholder, rebind observations/delegates/runtime bridges without stop/load, aggregate clear/archive/suspension protections, and source-ticket cancellation. Keep Quick/private behavior and explicit cross-profile reload consent.
- [ ] Step3: Add migration/restore tests for old5 data, unusable/duplicate window records, removal/focus/frame bounds and failed durable writes. Run focused real-WebKit, profile/Boost/output, startup and metadata checks.

### Task4: Native windows, commands and extension integration

**Files:** Modify BrowserAppDelegate.swift, ExtensionWindows.swift, ExtensionAdapters.swift, ExtensionTabs.swift, ExtensionRuntime.swift, extension host/client/action/source helpers and BrowserWindowOwner.swift; add scripts/BrowserMultiWindowNativeChecks.swift and actual runtime extension cases.

**Interfaces:** CmdN/New Window creates a new normal member; existing resurface/open-primary routes remain explicit for external/Quick handoff. AppDelegate maps each actual NSWindow to its member store/lease; close unregisters one member and all windows restore independently. Normal extension clients share one profile host with stable logical tab IDs/assigned windows and explicit source/target window guards.

- [ ] Step1: Add failing actual native two-window tests for CmdN, close-root/last-tab/reopen, local keyboard/Find/sidebar/Peek/fullscreen, document-safe output/Boost/media prompts and stale sources. Add extension cases for both normal windows, same-tab move identity, normal-vs-private refusal, clearing/deleting/host retirement and explicit extension window creation.
- [ ] Step2: Implement native/extension routing and source validation; run all targeted cases, preserving existing startup/Quick/native/fullscreen/extension tests. Verify real VM UI keyboard, clicks, resize, independent selection and unsaved-form handoff; record honest animation/AX limits.

### Task5: Verification, review and distribution

**Files:** Update build default checks, Info/version/release notes and docs/goal verification/acceptance records after product implementation.

- [ ] Step1: Run one frozen complete package gate, zero failures/diagnostics, both optimized architectures/universal/strict signatures/runtime/exact Info/min14/six entitlements, ZIP and mounted-DMG readback. Include meaningful shared-window regressions in headless checks and keep compositor/desktop cases explicit opt-ins.
- [ ] Step2: Obtain one fresh final implementation review; reproduce/fix Critical/Important findings in one pass and preserve all rulings/deferred minors. Verify affected and full gates after changes.
- [ ] Step3: Commit/push verified source, exact-source CI, new annotated0.10 preview tag, release CI and public download-back/live install/relaunch/update checks. Close only this plan's workspace. The complete Arc/browser objective and remaining acceptance areas stay active.

## Self-review
Task1 defines all pure model APIs used by Task2; group transactions and member lifecycle belong toTask2; view identity/render claims/clear protection and restore belong toTask3; native/extension/source-window behavior belongs toTask4; all five Review Focus classes have actual tests in their owning tasks. Metadata startup is BrowserMetadataLoading.swift/MetadataStartupView.swift; metadata persistence/schema are BrowserCore/MetadataStore.swift and BrowserCore/Profiles.swift. This plan's completion requires functioning windows, not the model foundation alone.
