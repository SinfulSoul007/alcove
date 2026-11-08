# Floating sidebar interaction and resize lifecycle

The complete browser goal remains in `docs/goal/acceptance.md`. This increment addresses the user's explicit rough-sidebar and resizing requirements without claiming that native animation or Arc parity is already verified.

## Investigation

The existing edge callback has no exit path after `revealed` becomes true; it relies entirely on a subsequent panel exit. Leaving between reveal completion and the panel's first hover event can leave the floating panel open. The hot zone is disabled upon reveal, so its exit is ambiguous. The controller also publishes token changes even when visibility is unchanged. Resize state accepts drag updates after cancellation, and the native handle has no Escape, key-window-loss or detach cancellation. A double-click reset followed by drag can therefore reuse a prior gesture's origin.

These are source/state-machine findings. Direct native reproduction and animation quality still require the denied test-app access. Owned-process regressions will establish the corrected event/lifecycle behavior.

## Approach

Use observation-only AppKit tracking areas for the left 8pt edge and floating panel. The edge stays tracked while revealed. A window-local reveal controller separately records edge/panel presence, native menu tracking and a resize hold. It retains the existing 90ms reveal and 240ms hide delays, cancels stale work and publishes only actual visibility changes. Track during native drags, keep tracking in the key window only, and never take click ownership.

Use explicit begin/drag/end/cancel semantics for the existing native resize handle. Escape, key-window loss and detach cancel transient width; double-click reset never begins a drag. Late drag/end events cannot revive a finished or cancelled gesture. Arrow-key steps commit once. Preserve the existing 196–360pt/window-fraction width bounds and default236 reset.

Alternatives: extending only SwiftUI `.onHover` leaves disabled-hot-zone and drag-event ambiguity; global pointer polling adds idle work and cross-window coupling. Native tracking and existing event-driven width state fit this AppKit browser. This is the executor's choice under the user's standing instruction to proceed without repeated design questions.

## Behavior and constraints

- A cancelled pending reveal never opens later. Leaving the edge after reveal schedules a hide even if no panel-enter event arrives. Entering either region cancels a stale hide.
- Native popup/context/menu tracking and an active sidebar resize hold an already-visible panel open. Ending a hold reevaluates the actual region state. Menus belonging to another window cannot hold this panel.
- A background/closing/detached window cannot retain a floating panel or revive it with stale callbacks. Attach/rebind observers weakly and release them with the controller.
- Disable floating reveal while pinned, in onboarding, command/Peek overlays, or a presented sheet. Keep sidebar and website hosts mounted. No visibility-state publication for mere token or pointer bookkeeping.
- Tracking backgrounds cannot hit-test, steal focus, or interfere with page/row clicks. Use public AppKit APIs, including tracking during drags; no pointer polling, global input synthesis, private APIs or screen capture.
- Resize updates only during a real gesture. Persist once on mouse-up or arrow-key completion. Cancel, double-click and idle mouse-up do not commit a stale width.
- Preserve macOS14 minimum, sandbox/signing labels, profile/session formats, themes and reduced-motion settings. No dependencies.

## Verification boundary

Pure state and owned hidden-window tests cover timing, cancellation, actual tracking options, window/menu ownership, native handle event routing and width persistence callbacks. Existing chrome/WebKit ownership tests cover integration. These tests do not establish onscreen animation smoothness, actual drag feel, accessibility or Arc pixel fidelity; those remain open.

References: [Apple tracking areas](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/EventOverview/TrackingAreaObjects/TrackingAreaObjects.html), [tracking during drags](https://developer.apple.com/documentation/appkit/nstrackingarea/options-swift.struct/enabledduringmousedrag), [native menu tracking completion](https://developer.apple.com/documentation/appkit/nsmenu/didendtrackingnotification).
