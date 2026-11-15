# Quick Browse Address Focus Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make initial, menu/button and repeated native address focus usable without losing editing or page state.

**Architecture:** Reuse the active NSText editor in QuickBrowseInput.Field; perform one responder transition when needed, then select within that editor. Controller, store and durable metadata APIs stay unchanged.

**Tech Stack:** Swift, AppKit, SwiftUI, WebKit, existing manual native checks.

**Spec:** docs/superpowers/specs/2026-11-14-quick-address-focus-design.md

## Global Constraints
- macOS14.0 minimum; public AppKit/SwiftUI only.
- Preserve data protection, six entitlements, profile/website ownership, release identity and the published0.9 assets.
- Do not modify the completed fullscreen plan or call this full browser/Arc completion.
- Native desktop tests are explicit opt-in commands, not part of headless CI.

## Review Focus
- Repeated address requests select a nonempty URL without generating a blur/cancellation cycle.
- Initial blank-window and website-to-address focus target the actual editor.
- Find uses the shared component and retains its query and repeated-selection behavior.
- A background or closed window cannot steal another window's editor.
- Focus transitions preserve unsaved input, document identity and the same mounted WKWebView.

### Task 1: Repair shared native editor focus

**Files:** Modify Sources/Browser/QuickBrowseUI.swift and scripts/build.sh; create scripts/QuickBrowseFocusChecks.swift.

**Interfaces:** Consumes existing Field.pendingFocus/currentEditor/window key state and QuickBrowseWindowController.requestLocation()/state.showFind(). Produces the same interfaces with reliable native focus and selection; no new public API.

- [x] Step1: Add actual-controller opt-in checks using private stores and owned local HTML. Cover all five Review Focus items, including a post-load unsaved value/token. No real browser profile or Keychain access.
- [x] Step2: Run scripts/build.sh quick-focus-test against unchanged QuickBrowseUI. Expected: native regression exits1 with address-focus assertions failing; fixture-ready and finished markers present, no compiler diagnostics. Fix fixture errors before implementation.
- [x] Step3: Apply the observed editor-reuse operation only inside QuickBrowseInput.Field.applyPendingFocus(). Keep genuine end-edit cancellation and the existing guards.
- [x] Step4: Run quick-focus-test and existing quick-native-test/ChromeChecks. Expected: all pass, no diagnostics. Build and live-test the established VisualFour candidate: menu/button/CmdL, repeat selection, Find, background/closed windows and unsaved page state.
- [x] Step5: Run full scripts/package.sh and existing strict bundle/readback gates with frozen inputs; require zero failures/diagnostics, both slices, minimum14 and exact six entitlements. Obtain one fresh review of this new task, resolve any Important/Critical findings by RED→GREEN once, preserve evidence and commit/push. Prepare patch0.9.1/build17 with matching v0.9.1-preview.1 metadata and release-note prose; preserve bundle identity and metadata format5. A new release needs its own tag and CI/download-back checks; previous0.9 release stays immutable.

## Self-review
One task owns the shared field operation. All five review items have actual native-controller assertions and live input verification. Existing fullscreen work remains unchanged and is not sent for another review. The full browser goal stays active.

Local/review/live/package gates completed at job143 (2,420 browser+1 ZIP, zero diagnostics,187 unchanged inputs). Source commit/push and the new0.9.1 exact-source CI/tag/public-download verification are the next integration actions; no public release completion is claimed by this plan checkbox. Full browser acceptance stays active.
