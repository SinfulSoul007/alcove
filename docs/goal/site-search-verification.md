# Configured site search — source verification

Developing source: 0.6.3 (build 10), candidate tag `v0.6.3-preview.1`; no new release or tag is published by this change. The public download remains 0.6.2 (build 9), tag `v0.6.2-preview.1` and its immutable assets. Full browser acceptance remains open in [acceptance.md](acceptance.md).

## Behavior

Primary and Quick Browse native inputs support shortcut → Tab → site query → Return. Exact or unique prefixes activate; ambiguous/unrelated Tab and Shift-Tab retain native handling. Empty Backspace restores the shortcut. Explicit site actions also activate from primary command results; ordinary Enter keeps its existing search/command behavior until a site is selected. Selected queries cannot become browser commands or tab matches.

A dedicated native settings panel supports add/edit/disable/delete and preset prefills, local validation, paused-save status and explicit shared-normal/temporary-private scope. Normal catalogs are encrypted before publication; private windows start with presets and keep changes in memory. Matching makes no network request. Queries navigate through the actual page, split, Peek or compact account. Changed owners/providers reject stale submission without a fallback search.

## Verification

`scripts/build.sh test` passed **814 browser checks**, with no failures or compiler diagnostics: 644 existing checks plus 57 site-search core, 46 store, 15 real WebKit/loopback and 52 native input/layout checks. This includes the existing chrome, compact window/native/lifecycle, profile, page-output and website suites. Owned fixtures use temporary metadata, supplied random keys, nonpersistent probe stores or randomly named website stores removed through their owned manifests; normal browsing data is not imported.

Both optimized `arm64` and `x86_64` bundles built successfully without compiler diagnostics into separate `build/site-search/` directories. Strict ad hoc signatures/Hardened Runtime, exact six entitlements, byte-identical source Info.plist, architecture and version/build/tag/minimum macOS metadata all passed. The test/review/live app bundles were not overwritten or launched. One fresh whole-branch review follows the Task 3 commit. No live native UI, physical Intel, macOS 14, quarantined-install, independent security-audit or Safari performance result is claimed.

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

## Deferred minors

Final review pending.

## Remaining scope

Automatic OpenSearch discovery/activation prompts and Air Traffic Control remain future work. Full Arc fidelity, native sidebar/navbar/resizing/drag/fullscreen/keyboard/VoiceOver and first-launch animations remain unverified in the live app. Boosts/Easels/capture, broader organization/splits/media, integrations/extensions, optional encrypted multi-Mac sync, everyday-browser gaps and all security/performance/hardware/install gates remain in the acceptance ledger. The full goal stays active.
