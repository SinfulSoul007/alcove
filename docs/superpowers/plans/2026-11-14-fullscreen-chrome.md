# Fullscreen Chrome Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep native-window navigation visible in fullscreen without replacing the website.

**Architecture:** NativeWindowChrome reconciles visibility of its own empty toolbar with the actual window fullscreen mask. Existing notifications and weak window ownership remain the lifecycle boundary.

**Tech Stack:** Swift, AppKit, SwiftUI, WebKit; existing manual build and native fixtures.

**Spec:** docs/superpowers/specs/2026-11-14-fullscreen-chrome-design.md

## Global Constraints
- macOS minimum 14.0; public AppKit/SwiftUI APIs only.
- Preserve all existing data protection, six entitlements and release identities.
- Do not modify the published v0.9.0-preview.1 tag or its assets.
- Preserve mounted website identity, page state and existing native button ownership.
- This is a fullscreen repair, not full Arc parity or a full-browser completion claim.

## Review Focus
- Repeated entry and exit restores the normal native-button baseline.
- Caller-supplied visible or hidden toolbars keep their visibility.
- A reader moved between windows cannot hide the wrong window's toolbar or retain the old window.
- Primary, collapsed-sidebar and Quick Browse keep their actual website mounted.
- Real fullscreen compositor behavior must match the hidden-fixture contract.

### Task 1: Reconcile only the owned toolbar

**Files:**
- Modify: Sources/Browser/NativeWindowChrome.swift
- Create: scripts/NativeChromeFullscreenChecks.swift
- Modify: scripts/build.sh

**Interfaces:**
- Consumes: NativeWindowChrome.attach(to: NSWindow), scheduleMeasurement(); native NSWindow styleMask and notifications.
- Produces: Existing chrome interface, with owned toolbars identified weakly, hidden in fullscreen and visible after exit. No new public entry points.

- [x] Step 1: Add standalone native checks for the unobscured fullscreen content rect, two entry/exit cycles, borrowed visible/hidden toolbar and reattachment. Keep the existing hidden production BrowserUI/Quick Browse alignment, hit-test, weak-window-release and mounted-WKWebView checks. The new fixture uses actual native transitions, a nonpersistent local web form and exact contentLayoutRect visibility.
- [x] Step 2: Run the lightweight fullscreen check against unchanged NativeWindowChrome. Expected: FAIL because fullscreen content remains under the empty owned toolbar; other failures, if any, must be diagnosed before implementation.
- [x] Step 3: Track only the toolbar created by this chrome owner. During scheduled native measurement, reconcile its visibility with the real window fullscreen mask before reading normal native-button geometry. Remember exact created toolbar objects weakly across reattachment; never identify ownership by string identifier.
- [x] Step 4: Run scripts/build.sh native-fullscreen-test (opt-in real GUI) and scripts/build.sh chrome-test. Expected: all PASS with zero compiler diagnostics. Repeat the visible guest probe with production code; native fullscreen must show the original navigation and normal exit must restore alignment. Inspect main and collapsed-sidebar UI and Quick Browse without replacing pages.
- [x] Step 5: Run scripts/build.sh test, optimized architecture builds and existing package checks before release. Expected: zero failures/diagnostics, unchanged minimum14 and six entitlements. Capture evidence and commit the verified change on fix/fullscreen-chrome. Public release remains unchanged until a separately verified artifact is produced.

## Self-review
One task owns all shared chrome behavior. Each acceptance requirement has a focused native or existing production-root check plus a live VM observation; the broader goal ledger remains open. No new browser feature or extension rereview is included.
