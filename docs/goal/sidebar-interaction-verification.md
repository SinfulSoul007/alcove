# Sidebar interaction verification — 2026-11-08

This source increment follows the native-chrome alignment work. It addresses floating-sidebar and resize lifecycle defects; the full browser goal and direct native animation/accessibility/Arc-fidelity gates remain active.

## Resulting behavior

- The edge stays tracked while the sidebar floats. Fast exits, missing panel-enter events, geometry changes and stale hover events resolve against current pointer state.
- Native menus and active resizing keep an already-visible panel open. Menu completion, window changes and detaching the last region release holds and cancel pending work.
- Only actual visibility changes publish to SwiftUI. Pointer/token bookkeeping does not invalidate the root layout.
- Escape, focus loss, key-window loss, close and detachment cancel transient resize width. Double-click reset does not start a drag; late or old-window input cannot save an abandoned width. Idle arrow-key steps commit once; arrow input during a held mouse gesture does not commit it prematurely.
- Pinned mode, command/Peek overlays, onboarding and sheets suppress floating reveal. Overlays also cancel an active resize in pinned and floating modes without saving transient width. The website and sidebar remain mounted; observation-only backgrounds cannot receive clicks or focus.

No new network capability, dependency, security entitlement or persistent document format is introduced. Pointer tracking is event-driven and window-local; it is not stored or transmitted.

## Evidence

Task1 passed26 focused lifecycle/native-tracking checks and all30 prior browser-chrome integration checks. Runtime failures before correction exposed a tracking region larger than its own bounds and a menu hold surviving the final region's detachment.

The clipping issue is explained by [Apple's macOS14 AppKit release notes](https://developer.apple.com/documentation/macos-release-notes/appkit-release-notes-for-macos-14): modern views do not clip to bounds by default, which affects `visibleRect`. The owned fixture observed a500×432 visible rectangle for an8×400 edge view. The tracker now clips its own bounds and intersects them when reconciling pointer position.

Task2's existing core API failed both late-drag regressions before correction. Additional owned event-handler tests reproduced stale hover input, focus-loss cancellation and old-window drag/up interference. The final focused suite passes **44 checks, zero failures and zero compiler diagnostics**. The core appearance checks pass23, including the two new late-drag cases.

Browser integration checks pass35, including five added cases exercising the actual `BrowserUI` root: floating reveal, website identity, page hit testing outside the panel, command-overlay suppression and stationary-pointer recovery. These fixtures substitute only key-window/pointer inputs and never show a window or operate a user app. Synthetic events are passed directly to owned handlers; no global input is synthesized.

The initial integrated run at `875f9ff` passed508 checks. Fresh read-only whole-branch review of `a3eb2c0..b1f6a93` found one Important/P2 issue and no Critical or Minor findings: an overlay could hide an active resize without cancelling it. Four actual-root persistence regressions reproduced the issue before correction. Source `0b6f830` gates native interaction on visibility/overlay state and cancels through a weak native connection from SwiftUI `onChange`, outside `updateNSView`.

The final integrated `scripts/build.sh test` run at source commit `0b6f830` passes **528 checks, zero failures and zero compiler or SwiftUI state-update diagnostics**. This includes55 browser-chrome checks: Peek, command and onboarding suppression in pinned/floating roots proactively cancel the gesture and reject late input without saving. These checks use disposable UserDefaults suites and never operate real app preferences. Two further checks cover the production sheet gate without presenting a native sheet.

Both optimized architecture builds were repeated after the fix and pass separate strict signature verification; the Intel Info.plist matches source. The source reviewer did not execute the app or independently verify binaries. No second review was performed after the single regression-backed fix pass.

## Rulings I made

1. **Global Escape routing:** cancel an active sidebar resize before dismissing Find/Peek/panels, so the grip receives cancellation. Tradeoff: the next Escape dismisses an already-open overlay.
2. **Stale hover delivery:** use the current own-window pointer and clipped geometry instead of replaying an obsolete event kind. Tradeoff: historical enter/exit transitions are discarded rather than animated after the pointer has moved.
3. **Responder focus loss:** cancel an active grip when another responder takes focus, including a Find command. Tradeoff: the uncommitted width is aborted rather than saved during that focus change.
4. **Input ownership:** require the current window's identity on mouse/key events as well as notifications. Tradeoff: unassociated or old-window synthetic input is ignored; normal focused input carries its window identity.
5. **Native sheet presentation:** cover the exact production blocking policy and common native disable/cancel path without presenting a sheet; live sheet QA remains open. Treating this as full coverage could miss native sheet focus or presentation defects.
6. **Onscreen reveal/spring/drag feel:** remains open until permitted native interaction. Treating it as complete could hide visible flicker or poor drag feel.
7. **Fullscreen and actual activation:** remain open; never-shown fixtures do not establish transition or activation behavior.
8. **Complete keyboard/focus/VoiceOver behavior:** remains open beyond the specific event-handler checks. Inaccessible controls or lost focus may remain.
9. **macOS14 execution:** remains open; deployment-target compilation does not establish runtime compatibility.
10. **Physical Intel execution:** remains open; cross-building does not establish hardware behavior.
11. **Arc fidelity and full feature parity:** remain unfinished in the acceptance ledger; passing these tests does not establish pixel or feature parity.
12. **Startup/frame-time/energy/many-tab performance:** remains unmeasured; no Safari-speed claim is supported.
13. **New-release distribution/install/update:** remains open until publication and artifact/update validation. Public0.6 remains unchanged and does not contain this source increment.
14. **Independent binary/signature/CI review:** declined by the source reviewer. Author-run optimized builds and strict signatures pass; new-source CI must run after push. These structural checks are not independent runtime or security certification.

## Remaining evidence

Live drag feel, animated reveal/hover behavior, fullscreen, keyboard/accessibility interaction, macOS14/physical Intel behavior, Arc pixel fidelity and the wider feature inventory are still unverified or unfinished. The public0.6 release remains unchanged. This increment can be batched with native chrome in the next public preview.

The previous native-chrome increment passed [GitHub CI42518774377](https://github.com/SinfulSoul007/alcove/actions/runs/42518774377) at `a3eb2c0`:457 browser checks plus two ZIP-verifier checks, both architecture builds and universal packaging. That evidence does not cover this later interaction source.

## Publication follow-up

The combined changes are now in public [0.6.1-preview.2](https://github.com/SinfulSoul007/alcove/releases/tag/v0.6.1-preview.2) at2250ccf. Two added scheduler-stall fixture checks and bounded transition waits bring the full suite to530 browser checks; browser code and timer policy remain unchanged from the reviewed fix. Source/release CI, download-back/mounted-image verification and live update selection pass. See [the release report](../releases/0.6.1-verification.md). This closes the source/artifact/public-catalog evidence for this preview, while actual installation, native interaction and the wider goal remain open.
