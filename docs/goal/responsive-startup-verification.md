# Alcove 0.7.2 protected-data startup verification

Keychain startup, closed-store recovery, background Quick Browse presentation and recovery feedback are fixed in source d58d2b1f4786a15c163128cf426ea8a98665c5a4. The stable Alcove Visual Four test app is updated in place to 0.7.2/build 14.

- Complete final local suite: 1,494 PASS,0 FAIL,0 compiler diagnostics.
- Focused startup: 31 PASS. Existing store 37 and native Quick 16 checks also passed before the full final suite.
- Optimized arm64/x86_64 bundles: strict signatures, Hardened Runtime, exact Info/version, minimum macOS 14 and unchanged six entitlements PASS.
- Exact-source CI: 1,494 browser+2 ZIP checks PASS,0 failures/compiler diagnostics. Run 42955609399 completed successfully.
- Artifact 13827821808 downloaded back: outer SHA/size, inner checksums, both CPU slices, per-slice signatures/runtime/entitlements/minimum, Info/license and mounted DMG contents PASS. DMG detached.

[Source commit](https://github.com/SinfulSoul007/alcove/commit/d58d2b1f4786a15c163128cf426ea8a98665c5a4) · [CI run](https://github.com/SinfulSoul007/alcove/actions/runs/42955609399)

## Behavior and native evidence

Default normal startup immediately shows loading/recovery UI while the Security call runs in the background. One pending lookup is shared across close/reopen; weak store continuations and shutdown/Quit guards reject late adoption/writes. Unknown profiles cannot open normal persistent website storage. Incoming HTTP(S) links wait in an owner-scoped bounded queue and use restored routing settings. Failure preserves sealed/legacy data and offers explicit retry. Private windows never request the metadata key.

Live Computer Use observed the actual Keychain wait with a responsive loading window. Open Private Window worked before approval. After the user completed the OS prompt, Private remained focused; closing it revealed saved Personal and the pre-existing Sidebar Test Space. The final app visibly restored an empty saved Quick Browse record without another prompt, then the test record was closed and normal browsing restored. No website URLs or new normal Spaces were added.

The final live key request completed before a second Private click, so final compact-only foreground/inactive restoration is verified by transparent owned native windows, not claimed as another live blocked-private sequence. Pure-hover/compositor/fullscreen/VoiceOver, actual Intel/macOS 14/quarantined installation, Safari performance and independent security audit remain broader acceptance gates.

## Review and fix pass

One fresh gpt-6-astra/high read-only whole-plan review found I1 hidden restored Quick windows and I2 invisible queue rejection, plus Minor M1 stale protected-data error after success. All entered one RED→GREEN fix pass under the user's request to fix remaining recovery issues. I1 now orders windows behind the current window and reveals existing hidden controllers; I2 is verified through the actual 65-link OS handler and OCR of rendered loading feedback; M1 separates Keychain errors from unrelated status messages. Final 1,494-check suite and both builds pass. No second reviewer was dispatched.

## Rulings I made, in order

1. Continue in the existing authorized main checkout with commit/push/build workflow — prior explicit user authorization. Cost if wrong: changes land on shared main.
2. Bound this increment to Keychain startup and dependent lifecycle/routing defects while retaining the full browser goal — independent unfinished features need separate verification. Cost if wrong: unrelated feature gaps remain meanwhile.
3. Preserve explicitly injected synchronous keyProvider fixtures; production defaults use background loading — avoid destabilizing unrelated owned fixtures. Cost if wrong: a caller deliberately supplying a synchronous provider can block its own caller.
4. Use live Computer Use for the SwiftUI Private Window button; a never-shown host exposes no AX children — keep mounted chrome transition and menu tests. Cost if wrong: native button action could remain unverified if access fails. The live button action passed.
5. Include startup-message Minor M1 in the same fix pass — the user explicitly requested Keychain and remaining issues, overriding the default minor deferral. Cost if wrong: adds focused test/gate work.
6. Leave cross-process read/save replacement to broader persistence work — the existing store lacks compare-and-swap, although metadata changed while Security waits is read afresh afterward. Cost if wrong: another process can race a later save. No general multi-process guarantee is claimed.
7. Closing the placeholder does not itself lose status messages — compact UI renders the same preserved store.message; the visibility bug was separately fixed. Cost if wrong: some warning could remain unavailable despite visible compact restoration.
8. Overlap exact-source CI with final local gates on independent machines after 31 focused passes — frozen sources avoid shared build state. Cost if wrong: main temporarily contains a regression until a failed gate is corrected. Both gates passed.

## Deferred minors and remaining scope

Previously deferred Boost M1 (Copy Appearance after Undo/Unhide selector state) and Sidebar M1 (floating-mode automated matrix coverage) remain separate work. No new startup-review finding remains open.

This is an unsigned/ad hoc preview. macOS may still require Keychain approval for changed unsigned code; no key, ACL, encryption namespace/format, Gatekeeper setting or entitlement was weakened. This fix removes the main-thread wait, not the system's authorization requirement. No new public release/tag was created; public distribution remains v0.6.2-preview.1 and these 0.7.2 deliverables are verified CI artifacts. Full Arc parity, Space management, extensions/sync/media and original security/performance/native gates remain unfinished.
