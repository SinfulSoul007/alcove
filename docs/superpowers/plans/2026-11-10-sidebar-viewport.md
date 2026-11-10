# Sidebar Viewport and Accessible Resizing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking. The user has already chosen autonomous inline execution in the existing checkout and opted out of repeated approval/mode gates.

**Goal:** Keep sidebar controls inside short windows and make resizing operable through keyboard/accessibility.

**Architecture:** Let the actual root viewport constrain sidebar height. Extend the existing native divider with public AppKit AX values/actions and first-responder focus, and add a dedicated focus hold to the existing floating reveal controller. Absolute resize commits avoid stale relative-step captures.

**Tech Stack:** SwiftUI, AppKit, WKWebView, existing manual Swift checks.

**Spec:** `docs/superpowers/specs/2026-11-10-sidebar-viewport-design.md`

## Global Constraints

- macOS 14 minimum; no dependency, private API, new entitlement or persistence-format change.
- Version 0.7.1/build13; candidate v0.7.1-preview.1. No public release/tag in this increment.
- Keep the existing Visual Four path, display name and bundle ID. Do not replace it while it cannot be closed through Computer Use.
- Hidden-window geometry/input evidence does not prove live compositor, VoiceOver or Arc fidelity.

## Review Focus

- A tiled window smaller than its nominal minimum must retain footer controls; test actual native menu rectangles in viewport coordinates at 960×494 and 760×400.
- Crowded Favorites plus large text must leave the footer available; test 24 Favorites/40 tabs at text1/1.35 and floating/pinned modes.
- Repeated synchronous AX actions and a viewport changing before SwiftUI redraw must clamp and accumulate; test real mounted handles and persisted defaults.
- A hidden/blocked/closed divider must reject stale actions without changing saved width; test cancellation, detached/replaced window and overlay lifetimes.
- Keyboard focus outside the floating panel must retain it without trapping focus forever; test actual responder ownership and focus-loss/resign/disable teardown.

### Task 1: Repair sidebar viewport and divider accessibility

**Files:**
- Modify: `Sources/Browser/BrowserUI.swift`, `Sources/Browser/SidebarInteraction.swift`, `Sources/Browser/SidebarRevealController.swift`
- Create: `scripts/SidebarLayoutChecks.swift`
- Modify: `scripts/SidebarInteractionChecks.swift`, `scripts/build.sh`, `scripts/Info.plist`
- Record: `docs/goal/sidebar-viewport-verification.md`, `docs/goal/acceptance.md`

**Interfaces:**
- Consumes: existing `SidebarSizing.width(saved: Double, windowWidth: Double) -> Double`, `SidebarResizeState` and reveal controller.
- Produces: `SidebarResizeHandle` accepts `width: Double`, `onSetWidth: (Double) -> Void`, `onFocusChange: (Bool) -> Void`; native Handle exposes `width: Double`, `setWidth: (Double) -> Void`, `focusChanged: (Bool) -> Void`. `SidebarRevealController.setKeyboardFocus(_ value: Bool)` holds an already revealed panel until focus loss.

- [x] Step 1: Add actual BrowserUI hidden-host regressions. Assert all sidebar NSPopUpButton bounds are inside viewport; preserve page identity and saved width through sizes 1260×820, 960×494, 760×400, scales1/1.35 and crowded/empty Favorites. Add `sidebar-layout-test` route and full-suite inclusion.
- [x] Step 2: Run `caffeinate -is scripts/build.sh sidebar-layout-test`. Expected: behavioral footer-bound failures on current root, with no compiler errors. Record measured overflow.
- [x] Step 3: Replace internal minimum canvas with actual fill sizing. Run the same command. Expected: viewport checks pass; retained page/defaults and zero geometry-only publications pass.
- [x] Step 4: Add real Handle AX tests for element/role/orientation/value/range, increment/decrement (+12), synchronous +24 accumulation, numeric set/clamp/reset, invalid values, actual focus, unavailable states and floating focus lifetime. Use existing NSView public methods so RED compiles before production API changes.
- [x] Step 5: Run `caffeinate -is scripts/build.sh sidebar-layout-test`. Expected: AX element/actions/value/focus fail on current handle. Add controller focus-hold test when its method is implemented; the root test must first demonstrate hiding while focused.
- [x] Step 6: Implement the specified public AX contract, clamped absolute setter, focus ring and dedicated reveal focus hold. Update raw Handle fixture to bind absolute commits without weakening mouse assertions. Keep cancellation outside representable updates. Run `caffeinate -is scripts/build.sh sidebar-layout-test`, `caffeinate -is scripts/build.sh sidebar-test`, `caffeinate -is scripts/build.sh chrome-test` sequentially. Expected: all pass, zero compiler diagnostics.
- [x] Step 7: Set version metadata. Commit code/tests/spec/plan. Run task-done with `caffeinate -is scripts/build.sh test`. Expected: whole suite PASS, zero diagnostics. Reuse the verified unchanged 9036553 baseline instead of rerunning it before RED.
- [x] Step 8: Build optimized arm64/x86_64 outputs sequentially, verify exact Info/signature/minimum14/architectures/six entitlements; record hashes. Expected: both bundles pass, native Visual Four untouched.
- [ ] Step 9: One fresh whole-plan final review (most capable available reviewer), regrade all findings and declined judgments; one Important/Critical RED→GREEN fix pass plus whole suite/build gates; defer minors. No second review.
- [ ] Step 10: Push authorized main; inspect exact-source CI to terminal, download and verify universal artifact/DMG contents and digests. Copy deliverables/evidence to thread outputs. Archive this plan's evidence and remove only its workspace. Full goal remains active.
