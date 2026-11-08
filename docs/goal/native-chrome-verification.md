# Native chrome verification — 2026-11-08

This is a source/UI increment after public 0.6, not a claim that the full browser goal is finished or a replacement of that release's immutable downloads.

## What changed

- Native compact titlebar layout and SwiftUI navigation now share measured geometry. AppKit retains the actual window buttons, their hierarchy and actions.
- Primary and Quick Browse navigation align at a measured 20pt center on this runtime. The primary's collapsed-sidebar header uses window coordinates and reserves the corresponding web-surface height.
- Quick Browse density/text changes preserve that baseline. Fixed action controls retain their width while the address field uses the remaining space.
- Window-local geometry updates preserve live WebKit views, ignore unchanged measurements, and detach observations when moving to another window.

## Evidence

The existing native lifecycle suite passed 16 checks before implementation. The first new check run failed because the shared chrome component did not exist. Runtime checks then exposed an invisible second header and an incorrectly placed private-window fixture sample; both were corrected before claiming alignment.

The first complete regression run passed 451 checks with no failures or compiler diagnostics. A later render exposed horizontal overflow that baseline checks alone missed: the large-text row was 779.5pt wide in a 760pt window, while the 480pt layout reduced its actions menu to 5pt. Six added actual native-menu/row-bounds checks failed first. Removing the address field's competing layout priority and fixing required control widths made all 30 focused checks pass without diagnostics.

Final owned renders show row widths of exactly 760pt and 480pt, a visible 25pt actions button inside both windows, and the Default profile name in the wide layout. The 1260×820 midnight and 800×540 cloud/text1.35 primary fixtures show no new control overlap. These are cached own-process hosting views; they omit native titlebar pixels and real website content. The measurements compare actual native button and rendered row bounds rather than duplicating a SwiftUI height formula.

Focused checks cover all three densities, text0.85/1.35, wide/minimum layouts, sidebar hide/reveal, theme change, actual top-of-web hit testing, native button ownership, noninteractive measurement views, unchanged native page identity, absence of store invalidations on resize, old-window release and unchanged-measurement coalescing.

Final integrated suite, optimized build, whole-branch review and source publication are recorded below when completed.

## Decisions and remaining gates

The implementation uses an empty transparent native compact toolbar and measures its controls through public APIs. Repositioning/reparenting native buttons and compressing the old row were rejected because of clipping/lifecycle/crowding risks. Geometry readers cannot receive input. No dependencies, session formats or security entitlements change.

Computer Use still denies the isolated Alcove Visual Four test app. Native dragging, animation, fullscreen transitions, keyboard/accessibility interaction, macOS-14 appearance and Arc pixel fidelity remain unverified. The complete goal and the broader feature gaps in `acceptance.md` remain active. No new DMG is claimed for this source increment; public 0.6 remains available.
