# Link routing source verification

Developing 0.6.4 / build 11 / tag candidate v0.6.4-preview.1; public 0.6.2 is unchanged. Full browser goal remains active.

Ordered Contains/Equals rules and Quick Browse/Most Recent Space/named Space destinations apply to external links, archive restoration and Peek opening. Normal configuration is encrypted before publication; private owners ignore it. Archive origin and recent-Space hints are optional format3 metadata. Same-profile Peek and unrelated-primary preservation retain real native views; a cross-profile opening requires scoped reload consent and uses a fresh view in the destination profile’s website store.

The complete post-review source suite passes **1,105 browser checks**, with zero failures or compiler diagnostics: 849 existing checks plus 122 routing core, 76 store, 27 real-WebKit and 31 native request/layout checks. The new native regression reproduced and fixed a callback-free primary Peek opening that skipped its operation; snapshot/window/duplicate/cancel/profile/rule/document guards pass. Both rebuilt optimized arm64 and x86_64 bundles pass strict ad hoc signatures, Hardened Runtime, exact six entitlements, architecture/minimum macOS 14 and byte-identical source Info.plist (0.6.4/build 11/candidate tag). The fresh whole-plan review found one Important account-selection defect (I1) and one Minor validation limitation (M1). I1 has focused RED→GREEN coverage and the post-fix full suite/build/signature gates pass. This record covers local verification; source CI and package results attach to the pushed commit.

The first full run failed an existing WebKit handoff fixture that invoked the new window-bound UI wrapper on an unmounted page, then timed out waiting for adoption. Mounting that owned page in a hidden NSWindow restores the original failed-save, recovery, form and atomic-publication assertions without weakening window validation; a new windowless-request check proves rejection leaves ownership intact. That pre-review full rerun passed 1,071 checks; the post-review I1 fix subsequently passed the complete 1,105-check suite. Two bundle-checker output-format assumptions (XML entitlements and combined ad hoc/runtime flags) were corrected using actual codesign output; no app/signature change was needed. Failed logs are retained in the local evidence.

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

12. exact Arc matching/ranking/account-memory/default behavior stays unverified — observed controls support this independent implementation but exact behavior needs live comparison — cost if wrong: workflows may differ from Arc until adjusted; the full goal remains open.

13. live Links/menu/settings/field-editor/sheet Escape/focus/IME/keyboard delivery remains a required open gate — hidden hosts and shared actions only verify logic and wiring — cost if wrong: interactive input or dismissal defects can remain.

14. live VoiceOver/accessibility tree/naming/order remains unverified — hidden AX hosts cannot establish usable accessibility — cost if wrong: the app can remain difficult or impossible to use with assistive technology.

15. live color/contrast/glyph/material/motion/reduced-motion/fullscreen/resize/hover fidelity stays open — cache geometry cannot prove these behaviors — cost if wrong: visible defects and rough interaction can remain despite source checks.

16. broader beforeunload/close/website modal/manual Quick-page and Space-close lifecycle stays in full-browser scope — routed Peek/external/archive handling improves immediate ownership without rewriting every existing closure path — cost if wrong: unrelated existing closure paths can still discard unsaved state until implemented and verified.

17. immediate preserved-Peek handoff does not guarantee state survives later opted-in tab suspension — the existing README explicitly warns suspension discards unsaved state and broader lifecycle work is still open — cost if wrong: a preserved background page can later lose state under that opt-in policy.

18. non-HTTP blob/data/about preview promotion, WebArchive opening and external protocols remain required broader content work — this routing increment deliberately handles HTTP(S), as the prior promotion paths did — cost if wrong: legitimate browser content workflows remain unavailable; do not count them as complete.

19. hostile-navigation/corrupt-metadata/recovery and independent audit gates stay open — finite normalization/ownership tests are not a complete security assessment — cost if wrong: untested attacks or recovery failures remain possible.

20. rule-list/startup/memory/energy/many-tab/Safari performance remains unverified — no benchmark or physical workload was run — cost if wrong: the browser may be slow or resource-heavy despite functional correctness.

21. physical Intel/macOS14/quarantined install/notarization/Gatekeeper/printer gates remain open — cross-builds/signatures do not prove those environments and no Apple Developer membership exists — cost if wrong: runtime, installation or print problems can remain; no security controls are weakened.

22. post-fix source CI/package verification belongs to the executor and new release publication remains outside this source plan — user authorizes source push, while public0.6.2 retains prior download-back evidence plus fresh metadata only — cost if wrong: an independent remote asset change is not detected by this review; inspect exact new source CI without claiming new public-byte verification.

23. full Arc/browser features remain in the original objective — Boosts/Easels/capture/extensions/sync/assisted workflows/media/PiP/permissions/import/export/downloads/website compatibility are explicitly incomplete — cost if wrong: major expected workflows remain missing; the browser goal cannot be marked complete.

24. first-run/sidebar/navbar/theme/multiple-normal-window and overall visual polish remain open — this feature review cannot establish the user's requested final experience — cost if wrong: original visible defects or missing workflows persist; keep the whole goal active.

## Fresh review and fix pass

The single fresh reviewer inspected 623351b..a0b6e9c and reproduced I1: scheme-less Equals conditions parsed under an invented HTTPS prefix could discard port 443, match the wrong HTTP endpoint/profile and miss HTTP port 80. Literal regressions reproduced eight matching/duplicate-condition failures and four store/account/dispatch failures before the fix. The matcher now prepares HTTP and HTTPS representations once, chooses the incoming scheme’s representation and compares both for duplicate conditions. Focused 122 core and 76 store checks pass with zero compiler diagnostics. The complete post-fix suite passes 1,105 checks. Both optimized architecture builds and exact Info/signature/entitlement gates pass with zero compiler diagnostics. No second review was performed.

## Deferred minors

**M1:** Equals conditions currently accept out-of-range ports above 65535, such as 99999. WebKit rejects those addresses, so the UI can save an unusable condition. This bounded validation issue remains open; no account crossover was demonstrated for it. It is deferred under the single-pass review workflow, not represented as a completed full-browser requirement.
