# Sidebar interaction implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make floating sidebar reveal and resizing recover correctly across fast pointer movement, menu use and gesture cancellation.

**Architecture:** A window-local `SidebarRevealController` owns timed visibility, pointer regions and holds. Noninteractive native `SidebarTracking` backgrounds deliver edge/panel events independently of click handling. The existing native resize handle gets an explicit cancellable lifecycle and preserves bounded transient width.

**Tech Stack:** Swift, AppKit, SwiftUI, system WebKit; macOS14 minimum.

**Spec:** `docs/superpowers/specs/2026-11-08-sidebar-interaction-design.md`

## Global constraints

- Preserve macOS14 minimum, sandbox/signing labels, profile/session formats, themes and reduced-motion settings.
- No dependencies, pointer polling, global input synthesis, private APIs or screen capture.
- Keep sidebar and website hosts mounted; publish only actual floating visibility changes.
- Keep existing 90ms reveal/240ms hide delays, 196–360pt/window-fraction width bounds and default236 reset.
- Native interaction/animation/accessibility/Arc fidelity and full-browser gates remain open.

## Review focus

- A fast edge exit between reveal completion and panel entry must not leave a stuck panel.
- Native menus and resize gestures must not hide the panel mid-interaction or couple different windows.
- Disabled overlays, window resignation and reattachment must cancel delayed/stale callbacks.
- Escape, double-click reset, detach and late drag/up events must not commit or resurrect transient width.
- Tracking areas and observer/task bookkeeping must not intercept clicks or continuously invalidate browser layout.

### Task 1: Event-driven floating sidebar lifecycle

**Files:**
- Create: `Sources/Browser/SidebarRevealController.swift`
- Create: `Sources/Browser/SidebarTracking.swift`
- Modify: `Sources/Browser/SidebarInteraction.swift` (move controller responsibility)
- Modify: `Sources/Browser/BrowserUI.swift`
- Create: `scripts/SidebarInteractionChecks.swift`
- Modify: `scripts/build.sh`

**Interfaces:**
- Consumes: existing `BrowserUI` mounted sidebar and `SidebarHoverState` generation behavior.
- Produces: `SidebarRevealController(enabled: Bool = false)` with `revealed`, `setEnabled(_:)`, `edgeEntered/edgeExited`, `panelEntered/panelExited`, `beginResize/endResize`, `reset()`, `attach(to:)`; `SidebarTracking(controller:region:enabled:)`, `.edge/.panel`, observation-only native `Host`.

- [x] **Step 1: Add focused behavioral checks** for cancelled reveal, edge exit with no panel-enter, hide cancellation, duplicate pointer-event publication count, menu holds/end/other-window isolation, window resignation/rebinding, disabled overlays and actual native tracking options/hit behavior. Use never-shown fixture windows, real NotificationCenter menu notifications and bounded async waits; no user apps/devices.
- [x] **Step 2: Add `scripts/build.sh sidebar-test`** compiling only the interaction sources and focused checks, plus the same checks in the full `test` route. Run focused checks against old code. Expected: missing explicit lifecycle interfaces or reproduced stuck-state failures; preserve RED evidence.
- [x] **Step 3: Implement controller and native tracking**, wire always-tracked edge and panel backgrounds into `BrowserUI`, gate by pinned/overlay state and replace the old ambiguous SwiftUI edge callbacks. Bridge resize begin/end to holds without replacing web hosts.
- [x] **Step 4: Run `scripts/build.sh sidebar-test` and `scripts/build.sh chrome-test`**. Expected: focused lifecycle/notification/hit checks and all existing30 geometry/WebKit checks pass without diagnostics. Commit the working task.

### Task 2: Cancellable native sidebar resizing

**Files:**
- Modify: `Sources/BrowserCore/SidebarInteraction.swift`
- Modify: `Sources/Browser/SidebarInteraction.swift`
- Modify: `Sources/Browser/BrowserUI.swift`
- Modify: `scripts/SidebarInteractionChecks.swift`
- Modify: `scripts/AppearanceChecks.swift`
- Update: `docs/goal/acceptance.md` and interaction verification report.

**Interfaces:**
- Consumes: Task1's `beginResize/endResize` and existing transient `SidebarResizeState`.
- Produces: `SidebarResizeHandle` initializer with `onCancel: () -> Void`; native `Handle` accepts `cancel` callback, guards drag/end by active gesture, cancels on Escape/key loss/detach and cleans observers. `SidebarResizeState.drag` ignores updates without an active transient width.

- [x] **Step 1: Add regressions** showing cancelled/finished widths cannot be revived by late drags; native Escape, key-window loss and detach cancel once; double-click plus drag/up produces reset only; ordinary drag and arrow steps commit once; callbacks reset on reattachment. Call event handlers only on owned hidden fixtures, with synthetic events addressed to those fixtures.
- [x] **Step 2: Run `scripts/build.sh sidebar-test`** before implementation. Expected: stale-resize or cancellation failures (or missing cancel interface); preserve RED evidence.
- [x] **Step 3: Implement cancellation** in core/native handle and UI. Do not persist cancelled widths. Preserve live drag bounds, keyboard steps, click routing and double-click reset236.
- [x] **Step 4: Run focused sidebar and chrome checks**. Expected: all pass without diagnostics. Run the complete `scripts/build.sh test` and optimized arm64/x86_64 builds once on final production sources; verify signatures. Commit and record final evidence.

Finish with one fresh whole-branch review required by inline execution. Grade all findings/declined behaviors, fix Important/Critical findings in one RED→GREEN pass, preserve remaining native/full-goal gates and push under the user's existing authorization. A new public release can batch these sidebar changes with the preceding native-chrome increment.
