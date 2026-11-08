# Native window chrome alignment

The full-browser goal remains in `docs/goal/acceptance.md`. This increment corrects a measured visual defect, and does not close the remaining Arc fidelity or native interaction gates.

## Evidence and intent

The 0.6 hidden-window fixture measures native traffic-light centers at 16pt, the primary navigation at 20pt, and Quick Browse navigation at 24–33pt depending on sidebar density/text scale. The collapsed-sidebar navigation is additionally displaced by its web-surface inset. A separate blank Arc private window was inspected through Computer Use: native window controls and navigation share one baseline. No user browsing data or Arc assets are included in the implementation/evidence.

An owned, never-shown AppKit probe establishes that an empty `.unifiedCompact` toolbar moves AppKit's actual controls into a consistent toolbar row (20pt center on this runtime). It preserves the full-size content frame and passes top-of-web hit testing. Accessory-only layouts leave the controls at 16pt. System geometry can vary by macOS; use live button bounds instead of assuming this runtime's coordinates.

## Approach

Use a transparent, non-customizable compact native toolbar with full-size content, preserving AppKit's actual buttons and their behavior. A window-local observable chrome object measures native button bounds in content coordinates and provides row height and a reserved leading edge. Noninteractive representable backgrounds in the actual SwiftUI navigation rows attach that object to the window and expose the rendered row's native bounds for verification. Observe native layout/window changes, coalesce measurements, and release observations with the root UI. No private selectors, native-button reparenting, frame rewriting or screen capture.

Alternatives considered: compressing controls to the old 16pt baseline crowds the address field; manually moving native buttons creates lifecycle/clipping risks; an accessory view alone does not fix the measured defect. The executor selects compact native chrome under the user's standing instruction to proceed without repeated design questions.

## Required behavior

- Primary sidebar, collapsed-sidebar header, and Quick Browse navigation center on the native window controls to within 0.5pt after layout.
- Reserve native-button width plus 16pt before the first custom control. Quick Browse text remains configurable but sidebar density does not move the native toolbar baseline.
- The collapsed header is positioned in root-window coordinates; its web surface reserves the corresponding height after the existing 8pt inset.
- Native controls remain in their original AppKit hierarchy. Web/sidebar/Peek ownership and browser state are unchanged by chrome updates.
- Resizing, text scale 0.85–1.35, all three densities, theme changes, hiding/revealing the sidebar, and attaching the root to a new window recompute correctly without retaining old windows or posting browser-store changes.
- Transparent measurement backgrounds cannot intercept clicks; the toolbar must not steal clicks from the top edge of a web surface outside the intended controls.
- Retain macOS 14 minimum and current sandbox/unsigned distribution labels. No new dependencies or persistence format changes.

## Evidence boundary

Own-process hidden-window geometry, hit testing and real nonpersistent WebKit identity are automated checks. Fixture renders supplement them. Actual native dragging, animation, fullscreen transitions, accessibility interaction, minimum-OS appearance and Arc pixel fidelity require Computer Use/device evidence; they remain open if app access is denied.

Public API references: [toolbarStyle](https://developer.apple.com/documentation/appkit/nswindow/toolbarstyle-swift.property), [native standard buttons](https://developer.apple.com/documentation/appkit/nswindow/standardwindowbutton(_:)), [titlebar accessories](https://developer.apple.com/documentation/appkit/nstitlebaraccessoryviewcontroller).
