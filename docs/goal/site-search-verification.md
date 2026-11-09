# Configured site search — source verification

Developing source: 0.6.3 (build 10), candidate tag `v0.6.3-preview.1`; no new release or tag is published by this change. The public download remains 0.6.2 (build 9), tag `v0.6.2-preview.1` and its immutable assets. Full browser acceptance remains open in [acceptance.md](acceptance.md).

## Behavior

Primary and Quick Browse native inputs support shortcut → Tab → site query → Return. Exact or unique prefixes activate; ambiguous/unrelated Tab and Shift-Tab retain native handling. Empty Backspace restores the shortcut. Explicit site actions also activate from primary command results; ordinary Enter keeps its existing search/command behavior until a site is selected. Selected queries cannot become browser commands or tab matches.

A dedicated native settings panel supports add/edit/disable/delete and preset prefills, local validation, paused-save status and explicit shared-normal/temporary-private scope. Normal catalogs are encrypted before publication; private windows start with presets and keep changes in memory. Matching makes no network request. Queries navigate through the actual page, split, Peek or compact account. Changed owners/providers reject stale submission without a fallback search.

## Verification

`scripts/build.sh test` passed **849 browser checks after the fix pass**, with no failures or compiler diagnostics: 644 existing checks plus 79 site-search core, 51 store, 17 real WebKit/loopback and 58 native input/layout checks. This includes the existing chrome, compact window/native/lifecycle, profile, page-output and website suites. Owned fixtures use temporary metadata, supplied random keys, nonpersistent probe stores or randomly named website stores removed through their owned manifests; normal browsing data is not imported.

Both optimized `arm64` and `x86_64` bundles built successfully without compiler diagnostics into separate `build/site-search/` directories. Strict ad hoc signatures/Hardened Runtime, exact six entitlements, byte-identical source Info.plist, architecture and version/build/tag/minimum macOS metadata all passed. The test/review/live app bundles were not overwritten or launched. The fresh whole-branch review of `b82ee13..a00af8a` found five Important issues and no Critical or Minor findings. All five were accepted by actual user effect for one fix pass, with no second review:

- Literal malformed percent escapes could consume the query's first characters. Validation now checks both template sides independently, including saved-catalog repair and failed-save rollback.
- Dot-only path expansions could normalize away the query. These submissions now stay local with an explanatory error; query-parameter and safely suffixed path templates remain usable.
- An editor could overwrite a newer enabled toggle. The actual editor save path now preserves the live flag; both directions are independently checked.
- A retired WebKit allocation's identity could be reused. Each Peek now has a lifetime UUID; primary drafts cancel synchronously and compact inputs observe that lifetime even when a native view is reused.
- App Escape recognized only NSTextView composition. Event handling and menu validation now share an NSTextInputClient-aware check, with a non-NSTextView first-responder regression.

The production-model/native probe evidence and exhaustive review limits are archived locally with this plan's evidence. The post-fix full suite passed all 849 checks with zero compiler diagnostics. All five findings have failing-before/passing-after coverage. Both post-fix optimized builds and exact signature/Info/six-entitlement gates also passed with no compiler diagnostics. No second review is claimed. This report covers local verification; CI results attach to the pushed commit. No live native UI, physical Intel, macOS 14, quarantined-install, independent security-audit or Safari performance result is claimed.

Owned host-cache PNGs were inspected at 480 and 760 points with text at 1.35× and in short primary/settings hosts. Native query/pill geometry and mounted-page identity are checked. AppKit material and accessibility-tree behavior in never-shown hosts do not reproduce a visible app or VoiceOver. This evidence cannot close the live keyboard, focus, sidebar, resizing or animation gates.

## Rulings I made

1. retain in-place/main and skip a redundant unchanged full baseline — standing user preference plus exact published source/CI already establish644 checks and both builds — cost if wrong: less integration isolation and an environmental baseline issue can first appear in new gates. Preserve per-task commits and one fresh final reviewer.

2. implement configured site search while native UI access remains unavailable — this is explicitly in the complete Arc inventory and improves the command experience; all original visual/smoothness gates remain open — cost if wrong: native polish is delayed while another requested feature advances, not redefined as complete.

3. normal profiles share an encrypted shortcut catalog; private owners use defaults and temporary changes — matches Arc's documented across-profile activation while query navigation remains owned by each actual account — cost if wrong: advanced users may want per-profile configuration later; no profile website data/history is shared by this feature.

4. keep the complete native/website suite at Task3 final-source gates while each intermediate task runs its affected focused/existing suites — avoid repeating unchanged UI/website builds before later planned production edits — cost if wrong: an unrelated integration regression may first surface at the final gate; per-task commits and focused gates keep it diagnosable. No full-suite success is claimed for developing site search yet.

5. start the owned site-search loopback fixture in the component route as well as later real-site checks — Command-T creates a real WebKit view, so it must never contact a fixed unowned localhost port — cost if wrong: small fixture startup overhead. Invalid-save simulation now targets an existing directory inside its own root, keeping MetadataStore parent-permission effects inside that root.

6. reconcile command context in both normal applyDocument and private commitQuickDocument — profile/Space publications bypass selection helpers, as the runtime REDs show — cost if wrong: an extra coupling to document publication; focused private/normal tests pin cleared drafts and metadata nonpersistence.

7. distinguish developing source metadata from the immutable public preview — advance source bundles to0.6.3/build10/tagv0.6.3-preview.1 in Task3 while public0.6.2/build9/tag/assets remain unchanged — cost if wrong: source builds can appear ahead of public releases, but they no longer misidentify new code as the published binary. No new tag/publication is created by this plan.

8. never-shown host windows report their actual inactive key state instead of overriding isKeyWindow=true — the fake active state caused AppKit end-editing notifications when pending focus was attempted, falsely clearing selected mode in a prohibited/background process — cost if wrong: these fixtures deliberately cannot establish live focus correctness; that remains an explicit native GUI gate. No production focus fix is claimed from this fixture failure.

9. use native query-origin geometry plus inspected owned PNGs for the pill-width regression — never-shown NSHostingViews expose no accessibility child tree, so the attempted static-text AX traversal was not a valid visual measurement — cost if wrong: geometry/render coverage does not establish live VoiceOver, focus or animation behavior; those remain open. The invalid AX traversal/diagnostic prints are removed from the test suite.

10. live keyboard/candidate-window/mouse focus, VoiceOver, animation and interactive resizing remain unjudged — hidden hosts and protocol probes do not establish live UI behavior and app access is unconfirmed — cost if wrong: live usability defects can remain despite green source fixtures; those acceptance gates stay open.

11. physical Intel/macOS14, quarantined installation, independent security audit and Safari performance remain open — this source increment has no supported evidence for those platform/device/trust claims — cost if wrong: runtime/install/performance/security issues may appear on those environments; no corresponding success claim is made.

12. automatic OpenSearch discovery/activation, Air Traffic Control and broader Arc parity remain future scope — these were explicitly retained outside this configured-search increment, with the full goal active — cost if wrong: expected Arc workflows remain unavailable until later work, not silently declared complete.

13. reviewer did not judge remote public-release immutability — its remit prohibited GitHub mutations/inspection, while this run has made no tag/release/asset changes and preserves public0.6.2 in source/docs — cost if wrong: an independent remote change would not be detected by this source review; the earlier download-back verification is not represented as a fresh one.

14. use per-Peek lifetime UUIDs and synchronous primary draft invalidation instead of ObjectIdentifier snapshots — owned WKWebView allocation immediately reused the retired address, violating stale-context rejection — cost if wrong: an extra ephemeral identity and earlier draft cancellation on preview changes; no metadata schema or website-store change. Compact UI observes that same lifetime, retaining native identity only for mounted view comparisons.

## Deferred minors

None. The reviewer reported no Minor findings; every Important finding entered the fix pass.

## Remaining scope

Automatic OpenSearch discovery/activation prompts and Air Traffic Control remain future work. Full Arc fidelity, native sidebar/navbar/resizing/drag/fullscreen/keyboard/VoiceOver and first-launch animations remain unverified in the live app. Boosts/Easels/capture, broader organization/splits/media, integrations/extensions, optional encrypted multi-Mac sync, everyday-browser gaps and all security/performance/hardware/install gates remain in the acceptance ledger. The full goal stays active.
