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

The final integrated `scripts/build.sh test` run at implementation commit `587b556` passed **457 checks, zero failures and zero compiler diagnostics**. Both optimized arm64 and x86_64 builds pass strict signature verification; the Intel bundle Info.plist matches source. The local isolated `Alcove Visual Four` bundle is refreshed as an arm64 test build and has not been launched through denied app access.

One fresh read-only whole-branch reviewer inspected `7afacb8..5d8bf93`, the spec/plan, surrounding code and verification logs. It identified **no Critical or Important defects** and judged the source increment ready. There is no second review or fix pass. Two optional coverage recommendations are recorded below; they do not establish a product defect or waive the full goal.

## Decisions and remaining gates

The implementation uses an empty transparent native compact toolbar and measures its controls through public APIs. Repositioning/reparenting native buttons and compressing the old row were rejected because of clipping/lifecycle/crowding risks. Geometry readers cannot receive input. No dependencies, session formats or security entitlements change.

Computer Use still denies the isolated Alcove Visual Four test app. Native dragging, animation, fullscreen transitions, keyboard/accessibility interaction, macOS-14 appearance and Arc pixel fidelity remain unverified. The complete goal and the broader feature gaps in `acceptance.md` remain active. No new DMG is claimed for this source increment; public 0.6 remains available.

## Rulings I made

Every behavior the reviewer declined to judge stays an open acceptance gate:

1. **Native dragging and interactive resizing:** geometry does not prove event behavior. Require actual interaction evidence. Cost if treated as done: missed drag/resize defects.
2. **Sidebar/hover animation:** tests deliberately disable motion. Require live animation verification. Cost if treated as done: flicker, jitter or hover failures can ship unseen.
3. **Fullscreen/titlebar reveal:** observers are implemented but native transition behavior is unverified. Cost if treated as done: overlapping controls or unstable geometry in fullscreen.
4. **Keyboard/accessibility:** bounds and native action targets are insufficient. Require keyboard and assistive interaction checks. Cost if treated as done: controls may be inaccessible despite correct layout.
5. **macOS 14 runtime:** compilation/current-system checks do not prove minimum-OS appearance or behavior. Cost if treated as done: users on the minimum version can encounter unsupported layouts or behavior.
6. **Intel hardware:** cross-compilation/signatures do not prove hardware execution. Cost if treated as done: Intel-specific runtime failures remain unseen.
7. **Arc pixel fidelity:** hosting renders omit native titlebar pixels and page content. Require direct comparison on the allowed test app. Cost if treated as done: visual mismatches remain.
8. **Installation/new-release distribution/full parity:** this is a source increment; existing public 0.6 is preserved and broader features remain unfinished. Cost if treated as done: people download an older UI or expect features that are still missing.

## Deferred minors

- Count native measurement executions, in addition to published changes, to directly verify work coalescing/stopping. Source inspection and current tests show equality-gated publication; they do not measure the work count. This is optional coverage, with no concrete runaway loop observed.
- Extend the automated responsive matrix around the 680pt breakpoint, long profile names and noncompact maximum text. Current automation covers all densities and type extremes at wide/small windows; the separately inspected 760pt/text1.35 render covers the large noncompact case. Further combinations remain part of visual QA.

## GitHub verification of the source increment

[CI42518774377](https://github.com/SinfulSoul007/alcove/actions/runs/42518774377) completed successfully at `a3eb2c0`. Its macOS job passed 457 browser checks plus two ZIP-verifier checks, both architecture builds and universal ZIP/DMG verification with zero compiler diagnostics. These are CI artifacts of that source, not a new public release or native onscreen certification.
