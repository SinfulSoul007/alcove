# Website fullscreen implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Provide genuine website fullscreen with preserved page state, window/profile ownership and normal browser interactions.

**Architecture:** Coordinate each real website view's intended host with WebKit's public fullscreen lifecycle. Defer conflicting chrome/modal/retirement operations until restoration, validating their captured context and delivering once. Qualify actual native behavior on a hosted Mac before integration/release.

**Tech Stack:** Swift/AppKit/SwiftUI/WebKit, owned native fixtures, existing GitHub manual workflow entry.

**Spec:** `docs/superpowers/specs/2026-11-24-website-fullscreen-design.md`

## Global constraints

- macOS 14+, both architectures; current six entitlements; no private API, signing/sandbox weakening, process tracing or global input control.
- Base `57a11f4462204eb380e28a9ab37ea1e7638313c9`; keep the live 0.21 pipeline/release separate and unchanged.
- Use real WebKit fullscreen, unchanged live documents and correct captured profile/window ownership. Inert Reader/internal views stay restricted.
- Owned local fixtures/scratch profiles only. No Keychain/user desktop. Existing pending VM unlock question is not repeated.
- A passing headless/model/flag check is not native, media, installed-app or full-goal qualification.

## Review focus

- SwiftUI remounts and host replacement during entry/exit must not steal the borrowed view or lose the latest destination.
- Late exit callbacks and repeated commands must complete once without acting on a replacement document/profile/window.
- A real warning, permission dialog or native sheet during fullscreen must remain visible and bound to its initiating page.
- Closing/clearing/transferring a presented page must release its native window and website-store ownership without false cleanup success.
- Static fullscreen pages, extension focus and normal OS-window fullscreen must remain correct alongside the new lifecycle.

---

### Task 1: Native lifecycle and view residency

**Files:** Create `Sources/Browser/WebsiteFullscreen.swift`, `scripts/WebsiteFullscreenChecks.swift`, `scripts/fullscreen/run-native.py`; modify `Sources/Browser/BrowserUI.swift`, `Sources/Browser/SplitDropWebHost.swift` and real website configuration creation in `BrowserStore.swift`, `PeekPanel.swift`, `QuickBrowseStore.swift`, `ExtensionTabs.swift`, `ExtensionSurfaceNavigation.swift` as needed. Branch-only manual `.github/workflows/native-erasure-check.yml` is the registered hosted entry; normal default packaging is separate.

**Interfaces:**
- A per-real-view coordinator exposes its captured logical owner, active/pending state, latest valid intended host and `exit(completion: @escaping @MainActor (Bool) -> Void)`. Bool means the captured presentation is restored/current; a stale operation receives false once.
- Host binding/reconciliation methods consume `(webView, store, intendedHost)` and public fullscreen/view-move signals. Keep ownership/cancellation data in the coordinator, not in arbitrary global window fallbacks.

- [ ] **Step 1: Add the actual owned native regression before implementation.** Check production preference; use an explicitly enabled control to observe genuine state/window/placeholder behavior. Require original document/form/scroll identity after exit and stable current host/viewport after SwiftUI mount/layout updates while borrowed. Include generic-element and video paths, entry/exit state timing and a replaced host/latest destination. Use synchronous AppKit main + Task + NSApp.run, watchdog and real condition waits.
- [ ] **Step 2: Compile/typecheck locally without launching GUI; commit/push validation-only branch and dispatch the hosted manual run.** Observe the actual baseline failure and bounded logs. Missing display/gesture support is an environment finding, not the intended RED; resolve it without weakening assertions.
- [ ] **Step 3: Implement the minimal coordinator and website preference configuration.** Observe entering state before borrowing, preserve the placeholder and intended host, reconcile only after real restoration. Validate store/profile/presentation ownership and support latest-host replacement; do not reload/recreate the page. Actual state/view-move timing determines the concrete bookkeeping; ledger deviations from the planned interface.
- [ ] **Step 4: Run the unchanged native regression GREEN for all five presentation contexts and normal/private variants.** Include width/height changes and stable document/history/forms; keep any unsupported video/PiP path an explicit open finding. Run existing chrome/split/Reader checks appropriate to touched ownership. Commit evidence and source.

### Task 2: Browser commands, prompts and teardown

**Files:** Modify `WebsiteFullscreen.swift`, `BrowserAppDelegate.swift`, `BrowserActions.swift`, `BrowserStore.swift`, `PeekPanel.swift`, `QuickBrowseStore.swift`, `WebsiteProtectionNavigation.swift`, `ExtensionSource.swift`, `ExtensionWindows.swift`, `BrowserTabCleanup.swift`; extend `WebsiteFullscreenChecks.swift` and add focused non-GUI lifecycle checks only where a real native failure needs a smaller repeatable contract.

**Interfaces:**
- Resolve an active WebKit presentation window to the captured logical browser window only while validated; never fall back across profiles.
- Restore-before-action accepts captured window/presentation and optional document identity plus a once-only continuation. It coalesces exit requests and cancels stale work, rather than selecting a later active page.
- Retirement/transfer paths request safe presentation exit while retaining the same view for a valid handoff or releasing it for close; pending cleanup remains honest if restoration cannot finish.

- [ ] **Step 1: Add native failing cases** for Escape precedence, Cmd-W/empty-window/app-alive, Cmd-L/find/Reader/output targeting, simultaneous exits, focus changes and stale callbacks. Add visible website-warning, media/script-sheet, extension window focus and static-page suspension checks. Include profile clear/delete, close during entry/exit, Quick/Peek retirement and actual same-profile window handoff preserving the exact draft.
- [ ] **Step 2: Observe RED before fixing each integration.** Use real WebKit transitions/owned pages and explicit assertions; do not merely drive a stand-in state machine. Inspect actual failures and only then add any smaller pure lifecycle test.
- [ ] **Step 3: Implement logical routing, deferred actions/modals and teardown.** Preserve existing captured-context guards; present prompts after restoration, complete/cancel exactly once, respect sheets/foreground focus and never replay a stale action onto another page. Keep private/profile/extension restrictions intact. Add fullscreen to cleanup protection; explicit user close/clear remains supported. Handle transfers without letting a retired callback blank a new owner's page.
- [ ] **Step 4: Run all Task 1+2 native checks GREEN and relevant existing regressions.** Verify actual window disappearance/owned store cleanup, current logical focus and no discarded source forms. Commit source/evidence, preserving any genuinely unproved media/GUI/hardware scope.

### Task 3: Full verification and integration

**Files:** Modify `scripts/build.sh` for appropriate durable focused tests; add `docs/website-fullscreen-verification.md` and update the acceptance ledger only to reflect observed results. Version/release updates occur only after gates establish a releasable candidate.

- [ ] **Step 1: Run the complete relevant browser suite, both optimized architecture builds and universal ZIP/DMG gates.** Require the exact final source, resource, signature and entitlement checks; no fake native success from package structure.
- [ ] **Step 2: Request one fresh bounded whole-branch review** using the spec, plan, review focus and ledger rulings. Re-grade material findings, fix them in one actual RED-to-GREEN pass, then run the required complete checks. Record deferred Minor findings and declined-scope rulings without dropping the original goal.
- [ ] **Step 3: Verify source/package download-back and native installed behavior when the approved VM is usable.** Preserve no-reload media/forms, native command/animation/AX behavior and the minimum-OS/Intel limitations explicitly. Integrate/publish only within the user's existing authorization and actual gates; do not mutate an active release candidate just to merge this feature early.

## Self-review / pre-flight

Task 2 consumes Task 1's real per-view session and exit result; its captured-action/document policy must not be inferred from whichever tab is active later. Task 3 consumes actual native evidence, not only a flag or pure-state result. The review-focus cases are assigned above. Probe timing may refine residency bookkeeping through an explicit ledger ruling; all specified user behavior remains binding. Existing 0.21 CI is monitored independently; new work stays on this branch.
