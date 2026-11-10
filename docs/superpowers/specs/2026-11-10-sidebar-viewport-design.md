# Sidebar viewport and accessible resizing

The full browser objective remains in `docs/goal/acceptance.md`. This increment repairs the two confirmed sidebar defects; it does not establish Arc parity or smooth compositor animation.

## Evidence and behavior

The installed Visual Four 0.6.2 sidebar loses its Library/Spaces/settings footer at a native 960×494 quarter tile. The root imposes an internal 800×540 frame even when its GeometryReader receives a smaller viewport. The divider is an NSView with an AXSplitter role but `isAccessibilityElement == false`, no value or actions, and no focus indication.

The mounted sidebar must use the actual viewport. Its fixed header/address, Space menu and footer remain inside the window at 960×494 and 760×400, with empty and crowded Favorites/rows, text scales 1 and 1.35, and pinned or revealed floating modes. Scrolling handles the tab/Favorite overflow. The usual NSWindow minimum remains 800×540. Resizing or toggling must preserve the same WKWebView, form/scroll state and saved width; geometry alone must not publish BrowserStore state.

The six-point divider is a real vertical accessibility splitter. It exposes a numeric current width and range 196…min(360, max(196, windowWidth×0.45)), based on the current native content viewport. Increment/decrement and idle Left/Right change width by 12 points, including repeated synchronous actions. Setting a finite numeric value clamps to the range; invalid values do nothing. An accessible Reset Sidebar Width action restores the default 236, clamped for the viewport.

The divider takes actual first-responder focus, draws a native focus ring, and reports focus coherently. A floating sidebar remains open while the divider has keyboard/accessibility focus, even outside its bounds. Focus loss resumes delayed pointer-based hiding. Hide, overlay, key-window loss, detach and close cancel gestures and clear focus holds. Disabled, detached or closed handles reject late accessibility actions and late input. Stale events from a previous window cannot save a width. A mouse drag remains transient until release; accessibility actions do not interrupt an active mouse drag.

## Boundaries

- macOS 14 minimum; no dependency, private API, new entitlement or persistence-format change.
- Version 0.7.1/build13; candidate v0.7.1-preview.1. No public release/tag in this increment.
- Keep the existing Visual Four path, display name and bundle ID. Do not replace it while it cannot be closed through Computer Use.
- Owned hidden-window tests establish geometry and input behavior only. Live animation, VoiceOver, native focus rendering and Arc visual comparisons remain open until the Mac is unlocked.
- Space management, remaining Boost minor M1 and all other original acceptance gates remain separate outstanding work.
