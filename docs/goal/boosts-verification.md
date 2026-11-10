# Site Boosts verification

Developing source0.7.0/build12 adds per-profile website appearance, custom CSS, explicitly approved page JavaScript, reversible element hiding and a native editor. The public release and stable Alcove Visual Four app remain0.6.2. This increment does not complete the full-browser acceptance ledger.

## Behavioral evidence

The final pre-review suite passes1,331 checks with zero failures or compiler diagnostics. Focused Boost suites comprise81 core,41 store/consent,58 actual-WebKit and46 native input/editor checks. Observed RED→GREEN regressions include unusable routing ports, profile identity repair retaining approval, consent during an in-flight load, cached-history duplicate feedback, source-close picker cleanup and marked-text Escape in the compact controller.

Actual WebKit fixtures cover strict-CSP styles, page globals/top-level await, retained back/forward documents, shared content controllers, profile/private/Peek/Quick ownership, stale callbacks, failed saves, duplicate picker messages and preserving live form nodes/scroll state. Owned native fixtures cover frozen source/profile drafts, stale edits, immediate appearance versus explicit code saves, isolated NSPasteboard sharing, single-use/late approval replies, window close and IME-aware cancellation. They do not establish live native focus or visual fidelity.

## Release configuration

Both optimized arm64 and x86_64 bundles build successfully without compiler diagnostics. Strict signature verification, Hardened Runtime, exact architecture, minimum macOS14 and byte-identical final Info.plist pass. Version0.7.0/build12/candidatev0.7.0-preview.1 is developing metadata; no tag or public release is created by this plan.

The existing six entitlements remain app sandbox, network client, user-selected read/write files, printing, camera and audio input. A separate owned non-UI probe compiles the actual parser and passes six valid/malformed/escaping async-body cases under the same sandbox/Hardened Runtime configuration. No JIT entitlement was added. This is current ARM-host evidence, not Intel-runtime or minimum-OS evidence.

## Native evidence and remaining gates

Computer Use now accesses the stable0.6.2 app. Its sidebar smoke test passes hide/restore, tab selection, pin/favorite/folder and Space switching; it also exposes footer clipping under native960×494 quarter tiling and missing Space deletion. These remain open in the full-goal ledger. No developing0.7 editor/prompt native interaction has yet been performed.

Owned hidden-host editor renders at600×300/620 and large text establish bounds/sticky-header/footer geometry only. AppKit material/control compositing artifacts make them unsuitable proof of actual control colors/readability. Live editor/consent layering, focus, keyboard, accessibility, animation, broad website compatibility, hardware/minimum-OS, installation, performance and independent security review remain open.

## Review and publication

Task completion, one fresh whole-plan source review, any required single RED→GREEN fix pass, exhaustive ruling/minor report, evidence archival, source push and exact-source CI/package inspection are pending. No trusted Developer ID/notarization, Safari-speed or full Arc parity claim is made.
