# Native window chrome implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Align native and SwiftUI browser controls across window layouts without disturbing live websites.

**Architecture:** One window-local `NativeWindowChrome` observes public AppKit geometry. `NativeChromeReader` attaches from each SwiftUI toolbar background and remains transparent to input. Primary and Quick Browse share the measured baseline.

**Tech Stack:** Swift, AppKit, SwiftUI, system WebKit; macOS 14 minimum.

**Spec:** `docs/superpowers/specs/2026-11-08-native-chrome-design.md`

## Global constraints

- Retain macOS 14 minimum and current sandbox/unsigned distribution labels.
- No private selectors, native-button reparenting, frame rewriting or screen capture.
- No new dependencies or persistence format changes.
- Preserve web/sidebar/Peek ownership and browser state across chrome updates.
- Keep full-browser acceptance and unavailable native gates open.

## Review focus

- Collapsed-sidebar headers must align in root coordinates despite the web surface's 8pt inset.
- Large text and spacious density must fit the compact header without moving its baseline.
- Resize and theme changes must preserve native WebKit identity and input at the viewport's top edge.
- Moving a root to another window must detach old observations; old windows must not be retained.
- Native layout notifications must coalesce and stop; geometry updates must not publish browser-store changes.

### Task 1: Shared native chrome and actual layout regressions

**Files:**
- Create: `Sources/Browser/NativeWindowChrome.swift`
- Modify: `Sources/Browser/BrowserUI.swift`
- Modify: `Sources/Browser/QuickBrowseUI.swift`
- Create: `scripts/ChromeChecks.swift`
- Modify: `scripts/build.sh`
- Update: `docs/goal/acceptance.md`

**Interfaces:**
- Consumes: `BrowserUI(store:)`, `QuickBrowseUI`/`QuickBrowseWindowController`, existing private `BrowserStore` and real nonpersistent `WKWebView`.
- Produces: `@MainActor NativeWindowChrome: ObservableObject` with `height`, `leadingEdge`, `attach(to: NSWindow)`, and `scheduleMeasurement()`; `NativeChromeReader: NSViewRepresentable` with native `Host` backgrounds in actual rows.

- [ ] **Step 1: Write native layout regressions** in `scripts/ChromeChecks.swift`. Mount actual primary/Quick Browse UI in never-shown windows. Assert row/native centers differ by at most 0.5pt, controls clear native buttons, compact and wide resize/text/density/theme/hide/reveal cases preserve the same nonpersistent web view, reader hit testing is nil, native button targets stay in the AppKit hierarchy, and root moves/teardown do not retain the old window or generate store invalidations. Compare actual row bounds, not a duplicated layout formula.
- [ ] **Step 2: Run the new focused check** with `scripts/build.sh chrome-test`, adding its compilation mode first. Expected: failure from the missing native chrome component or measured baseline mismatch; preserve RED evidence.
- [ ] **Step 3: Implement shared geometry** in `NativeWindowChrome.swift`; wire both UI roots to the measured height/leading edge. Move the collapsed navigation outside the inset content; preserve existing mounted content and transitions. Observe public native frame/resize/backing/fullscreen notifications with coalesced main-thread work, weak ownership and idempotent attach.
- [ ] **Step 4: Run `scripts/build.sh chrome-test`**. Expected: all geometry, hit/identity and lifecycle checks pass with no compiler diagnostics. Extend focused coverage for any discovered failure before fixing it.
- [ ] **Step 5: Render the existing owned fixtures** using `work/visual-qa/RenderChrome.swift` and inspect the hosting PNGs. Expected: no clipping/overlap at 1260×820 and 800×540/text1.35; native screenshots/animation remain explicitly unverified if access is denied.
- [ ] **Step 6: Run `scripts/build.sh test` and an optimized build**. Expected: full suite green and no diagnostics. Record acceptance evidence, then commit the implementation, tests, and evidence summary.

Finish with one fresh whole-branch review required by inline execution; fix Important/Critical findings in one RED→GREEN pass. Preserve the review decisions and evidence. Push only verified work under the user's existing authorization; a new public release is not required for this individual geometry change.
