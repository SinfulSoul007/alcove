# Arc interface and interaction pass

The user rejected the generic 0.2 interface and requested Arc-like resizing, navbar, UI and experience. Arc for Mac was inspected through the native UI without modifying its tabs or account data. Arc’s source/assets and the user’s browsing data are not copied into the repository.

Implemented reference structure: sidebar-only compact navigation; native window controls; icon Favorites, persistent pins/folders, Today and bottom Spaces; dark default and per-Space themes; bounded sidebar resizing and edge reveal; keyboard-first command/find; pinned home destinations; draggable tab sections; Shift-click Peek; focused split-pane actions. No decorative homepage or full-width toolbar remains.

Behavioral checks exercise minimum/maximum/sidebar-to-window sizing, cross-Space drag and selection repair, pinned close/reset, cancelled Command-T, precise command matching, focused split actions, Peek view replacement and repeated Unlock prevention. Existing encrypted-storage and private-mode checks remain in the suite. Startup Keychain authentication never blocks invisibly before a window; user-initiated Unlock performs the interactive retry.

Review findings fixed: replacing a Peek’s native view, concurrent unlock restores, explicit Peek shutdown on window closure. Native verification observed sidebar resize, window zoom, immediate Command-T typing, Find no-match feedback, same-origin site icon display, Shift-click Peek and replacing its destination. Native automation had stale-instance and window-edge-drag failures, so those failed calls are not counted as successful minimum-window drag tests. Geometry limits and split-pane sizing have automated/source validation; minimum macOS and Intel hardware tests remain open.

Distribution: v0.2 DMG was built successfully on GitHub’s macOS runner after local disk-device creation failed. The workflow now takes a validated release tag and can create a DMG from the verified ZIP for v0.3 and future previews. DMGs are mounted, signature checked and executable-compared before publication. No claim of trusted Developer ID signing, notarization, complete Arc parity or perfection is made.
