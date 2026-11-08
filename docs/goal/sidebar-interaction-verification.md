# Sidebar interaction verification — 2026-11-08

This source increment follows the native-chrome alignment work. It addresses floating-sidebar and resize lifecycle defects; the full browser goal and direct native animation/accessibility/Arc-fidelity gates remain active.

## Resulting behavior

- The edge stays tracked while the sidebar floats. Fast exits, missing panel-enter events, geometry changes and stale hover events resolve against current pointer state.
- Native menus and active resizing keep an already-visible panel open. Menu completion, window changes and detaching the last region release holds and cancel pending work.
- Only actual visibility changes publish to SwiftUI. Pointer/token bookkeeping does not invalidate the root layout.
- Escape, focus loss, key-window loss, close and detachment cancel transient resize width. Double-click reset does not start a drag; late or old-window input cannot save an abandoned width. Idle arrow-key steps commit once; arrow input during a held mouse gesture does not commit it prematurely.
- Pinned mode, command/Peek overlays, onboarding and sheets suppress floating reveal. The website and sidebar remain mounted; observation-only backgrounds cannot receive clicks or focus.

No new network capability, dependency, security entitlement or persistent document format is introduced. Pointer tracking is event-driven and window-local; it is not stored or transmitted.

## Evidence

Task1 passed26 focused lifecycle/native-tracking checks and all30 prior browser-chrome integration checks. Runtime failures before correction exposed a tracking region larger than its own bounds and a menu hold surviving the final region's detachment.

The clipping issue is explained by [Apple's macOS14 AppKit release notes](https://developer.apple.com/documentation/macos-release-notes/appkit-release-notes-for-macos-14): modern views do not clip to bounds by default, which affects `visibleRect`. The owned fixture observed a500×432 visible rectangle for an8×400 edge view. The tracker now clips its own bounds and intersects them when reconciling pointer position.

Task2's existing core API failed both late-drag regressions before correction. Additional owned event-handler tests reproduced stale hover input, focus-loss cancellation and old-window drag/up interference. The final focused suite passes **44 checks, zero failures and zero compiler diagnostics**. The core appearance checks pass23, including the two new late-drag cases.

Browser integration checks pass35, including five added cases exercising the actual `BrowserUI` root: floating reveal, website identity, page hit testing outside the panel, command-overlay suppression and stationary-pointer recovery. These fixtures substitute only key-window/pointer inputs and never show a window or operate a user app. Synthetic events are passed directly to owned handlers; no global input is synthesized.

Optimized arm64 and x86_64 builds pass without compiler diagnostics. Final integrated suite, strict signatures and independent review are recorded after verification.

## Rulings I made

1. **Global Escape routing:** cancel an active sidebar resize before dismissing Find/Peek/panels, so the grip receives cancellation. Tradeoff: the next Escape dismisses an already-open overlay.
2. **Stale hover delivery:** use the current own-window pointer and clipped geometry instead of replaying an obsolete event kind. Tradeoff: historical enter/exit transitions are discarded rather than animated after the pointer has moved.
3. **Responder focus loss:** cancel an active grip when another responder takes focus, including a Find command. Tradeoff: the uncommitted width is aborted rather than saved during that focus change.
4. **Input ownership:** require the current window's identity on mouse/key events as well as notifications. Tradeoff: unassociated or old-window synthetic input is ignored; normal focused input carries its window identity.

## Remaining evidence

Live drag feel, animated reveal/hover behavior, fullscreen, keyboard/accessibility interaction, macOS14/physical Intel behavior, Arc pixel fidelity and the wider feature inventory are still unverified or unfinished. The public0.6 release remains unchanged. This increment can be batched with native chrome in the next public preview.

The previous native-chrome increment passed [GitHub CI42518774377](https://github.com/SinfulSoul007/alcove/actions/runs/42518774377) at `a3eb2c0`:457 browser checks plus two ZIP-verifier checks, both architecture builds and universal packaging. That evidence does not cover this later interaction source.
