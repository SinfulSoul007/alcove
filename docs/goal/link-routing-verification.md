# Link routing source verification

Developing 0.6.4 / build 11 / tag candidate v0.6.4-preview.1; public 0.6.2 is unchanged. Full browser goal remains active.

Ordered Contains/Equals rules and Quick Browse/Most Recent Space/named Space destinations apply to external links, archive restoration and Peek opening. Normal configuration is encrypted before publication; private owners ignore it. Archive origin and recent-Space hints are optional format3 metadata. Same-profile Peek and unrelated-primary preservation retain real native views; a cross-profile opening requires scoped reload consent and uses a fresh view in the destination profile’s website store.

The final complete source suite passes **1,071 browser checks**, with zero failures or compiler diagnostics: 849 existing checks plus 93 routing core, 71 store, 27 real-WebKit and 31 native request/layout checks. The new native regression reproduced and fixed a callback-free primary Peek opening that skipped its operation; snapshot/window/duplicate/cancel/profile/rule/document guards pass. Both optimized arm64 and x86_64 bundles pass strict ad hoc signatures, Hardened Runtime, exact six entitlements, architecture/minimum macOS 14 and byte-identical source Info.plist (0.6.4/build 11/candidate tag). Fresh whole-plan review and source CI remain pending.

The first full run failed an existing WebKit handoff fixture that invoked the new window-bound UI wrapper on an unmounted page, then timed out waiting for adoption. Mounting that owned page in a hidden NSWindow restores the original failed-save, recovery, form and atomic-publication assertions without weakening window validation; a new windowless-request check proves rejection leaves ownership intact. The final full rerun passes. Two bundle-checker output-format assumptions (XML entitlements and combined ad hoc/runtime flags) were corrected using actual codesign output; no app/signature change was needed. Failed logs are retained in the local evidence.

Owned cache renders were inspected at 600pt, short height and text scale 1.35. They establish bounded structure and native website ownership, not full control rendering or live interaction: native controls/materials appear as blank cache regions, and hidden SwiftUI hosts expose no AX children. Direct Alcove Visual Four access is still denied. Arc's actual Contains/Equals and three-destination menus were observed without editing preferences; exact matching/profile/default semantics remain unproven. No app permission bypass, Gatekeeper change, test-app replacement or new public release occurred.

All original sidebar/navbar/resizing/animation/fullscreen/keyboard/VoiceOver, first-run, full-feature, security/performance, physical Intel / macOS 14 and quarantined-install gates remain open. Exhaustive ledger rulings and final review disposition will be preserved here before completion of this source increment.

## Rulings I made

1. keep inline/main and skip redundant unchanged full baseline — standing in-place/no-design-question/commit-push preference plus verified exact623351b local/CI849 checks and both builds — cost if wrong: less isolation and environmental baseline issues may surface in new gates. Preserve per-task commits and one fresh final reviewer.

2. use the brainstorming opt-out and builder/approval exception — the user has already delegated implementation choices and requested continuous work — cost if wrong: our documented matching/default/safety decisions may need adjustment after direct user/native comparison; no invented approval is claimed.

3. native rules expose both observed URL modes and all three observed destinations, with explicit documented normalization/priority/profile policy — read-only UI proves controls, not behavioral edge semantics — cost if wrong: exact Arc behavior may differ; retain live fidelity gates and tests for our actual behavior.

4. preserve an unrelated primary Peek as a same-profile ordinary tab in the same opening candidate — existing Space-opening hooks close it and would lose live forms during automatic routing — cost if wrong: an extra tab appears, but no form/history/cookies are transferred or lost; UI explains preservation generically.

5. share canonical host parsing with remembered-profile routing — Foundation's owned probe preserves numeric aliases and malformed[:::], while the URL Standard/WebKit use canonical browser hosts — cost if wrong: ambiguous legacy host choices can normalize differently; first valid canonical choice and actual-engine comparisons pin safe account selection.

6. accumulate the full native/website suite on final Task3 sources, with affected focused/existing gates per task — avoid repeatedly rebuilding unchanged UI before the next planned edits — cost if wrong: an integration issue may surface later; per-task commits and focused tests isolate it.

7. advance developing source to0.6.4/build11/candidate tag at final integration, retaining public0.6.2 and prior source artifacts — distinguish this new routing increment from verified0.6.3 source — cost if wrong: source versions run ahead of public previews; no new public tag/release is created.

8. normalize browser dot path segments while retaining escaped separators, and retain the caller's literal Contains prefix when its URL has no path — canonical browser destinations must match while substring conditions must not silently grow a slash boundary — cost if wrong: Arc's precise normalization may differ; direct model regressions and later actual-engine comparisons pin this behavior, with live fidelity still open.

9. test the shared Done save/dismiss action and inspected owned geometry/renders, with actual command/menu entry checks, while leaving Settings-button clicking/VoiceOver/live-focus acceptance open — hidden SwiftUI hosts expose no AX children and cannot establish those behaviors — cost if wrong: native button or accessibility wiring can still have an integration defect; final source review inspects bindings and live app access is still required.

10. retain owned cache renders as limited geometry evidence, not full visual correctness — inspected600x360/620 and Settings PNGs expose structure/text-field positions but native controls/materials render as white/transparent cache regions in never-shown hosts — cost if wrong: contrast/glyph/native control defects can remain; require live Alcove permission and do not close visual/accessibility gates.

11. keep native expansion window-bound and mount the existing real-WebKit failure/recovery fixture in an owned hidden NSWindow — exercise the actual new UI contract without a permission bypass or weakening stale-window validation — cost if wrong: never-shown windows still cannot establish focus/animation/live consent; preserve all old rollback/form/atomic-publication assertions and add a windowless-request guard check. Rerun affected gates then the full suite/builds; do not claim the first full run passed.

## Deferred minors

Pending the fresh whole-plan review. No review verdict is claimed yet.
