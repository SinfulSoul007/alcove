# Site Boosts verification

Developing source0.7.0/build12 adds per-profile website appearance, custom CSS, explicitly approved page JavaScript, reversible element hiding and a native editor. The public release and stable Alcove Visual Four app remain0.6.2. This increment does not complete the full-browser acceptance ledger.

## Behavioral evidence

The final post-review suite passes1,392 checks with zero failures or compiler diagnostics. Focused Boost suites comprise81 core,62 store/parser,95 actual-WebKit and49 native input/editor checks. Observed RED→GREEN regressions include unusable routing ports, profile identity repair retaining approval, consent during an in-flight load, cached-history duplicate feedback, source-close picker cleanup and marked-text Escape in the compact controller.

Actual WebKit fixtures cover strict-CSP styles, page globals/top-level await, retained back/forward documents, shared content controllers, profile/private/Peek/Quick ownership, stale callbacks, failed saves, duplicate picker messages and preserving live form nodes/scroll state. Owned native fixtures cover frozen source/profile drafts, stale edits, immediate appearance versus explicit code saves, isolated NSPasteboard sharing, single-use/late approval replies, window close and IME-aware cancellation. They do not establish live native focus or visual fidelity.

## Release configuration

Both optimized arm64 and x86_64 bundles build successfully without compiler diagnostics. Strict signature verification, Hardened Runtime, exact architecture, minimum macOS14 and byte-identical final Info.plist pass. Version0.7.0/build12/candidatev0.7.0-preview.1 is developing metadata; no tag or public release is created by this plan.

The existing six entitlements remain app sandbox, network client, user-selected read/write files, printing, camera and audio input. A separate owned non-UI probe compiles the actual parsers and passes12 valid/malformed/escaping JavaScript and executable CSS-preflight cases under the same sandbox/Hardened Runtime configuration. No JIT entitlement was added. This is current ARM-host evidence, not Intel-runtime or minimum-OS evidence.

## Native evidence and remaining gates

Computer Use now accesses the stable0.6.2 app. Its sidebar smoke test passes hide/restore, tab selection, pin/favorite/folder and Space switching; it also exposes footer clipping under native960×494 quarter tiling and missing Space deletion. These remain open in the full-goal ledger. No developing0.7 editor/prompt native interaction has yet been performed.

Owned hidden-host editor renders at600×300/620 and large text establish bounds/sticky-header/footer geometry only. AppKit material/control compositing artifacts make them unsuitable proof of actual control colors/readability. Live editor/consent layering, focus, keyboard, accessibility, animation, broad website compatibility, hardware/minimum-OS, installation, performance and independent security review remain open.

## Review and publication

All four implementation tasks and one fresh whole-plan source review are complete. Four Important findings were reproduced and fixed in one pass:

- CSS errors: structural-only validation was insufficient. Changed CSS now needs an exact-text receipt from an owned, nonpersistent WebKit parser before persistence. Runtime validation also retains working sheets on failure. Invalid/partial rules, selectors and values preserve the draft, prior record and encrypted bytes; supported empty/comment, nesting, escapes, layers, keyframes and font-face cases pass. Validation never adopts the sheet and uses a page with default-src none. Asynchronous saves recheck draft/profile/content and cancellation; late Done cannot dismiss another panel.
- Hiding: reversible inline-important display overrides replace the defeated final author layer. Actual site/custom layers, inline-important styles, new nodes, later page display changes and exact Undo/form preservation pass. Site scripts may observe style mutations; broad dynamic/performance QA remains open.
- Picking: generic window capture interception is installed at document start and becomes inactive on exit. Synthetic real-engine propagation tests preserve the live form and prevent page pointer/mouse/click handlers, then verify input resumes. Trusted desktop input is still a native QA gate.
- Text size: root/rem scaling measures the unboosted site baseline instead of the browser initial font. Actual10px/24px roots,75/100/125 percent, repeated changes, off and unchanged fixed-pixel descendants pass. The UI states that fixed-pixel text is unchanged; broad responsive/animated/important-layer font compatibility remains open.

One Minor remains deferred: Copy Appearance after Undo/Unhide can export selectors from the stale draft, so an imported appearance may re-hide restored elements. A latest-selector clipboard snapshot must preserve unsaved name/code fields.

The first final full run stopped after907 passes and one existing sidebar delayed-hide failure, without compiler diagnostics. System logs show22 seconds of sleep immediately before that suite finished. The unchanged compiled sidebar suite then passed46/46 checks three times. The same source's full rerun passed1,392/1,392; an idle-only assertion initially allowed maintenance sleep, so an AC-only process assertion was attached to that live run. No timing assertion/timeout was weakened, no run restarted solely on an observation timeout, and the temporary assertion processes were confirmed exited. This is evidence for the environment diagnosis, not a native smoothness result.

Source push, exact-source CI/package inspection, exhaustive user-facing ruling/minor report and evidence archival follow these local gates. Public0.6.2 remains unchanged. No trusted Developer ID/notarization, Safari-speed or full Arc parity claim is made.

## Decisions and costs

1. Ruling: Use inline/main and skip fresh design/approval/builder gates under the standing user opt-out — preserves their explicit execution preference — cost if wrong: later UI choices may need revision. No per-task agents; one final reviewer only.

2. Ruling: Reuse the exact clean-head baseline suite/CI evidence instead of repeating unchanged baseline work — current head has no product changes and prior 1,105-check CI succeeded — cost if wrong: an environment-only regression will first surface in focused/full task gates.

3. Task 2: Ruling: Use explicit latest-record enable/zap mutators, with expected-content editor saves — prevents an old editor overwriting newer controls — cost if wrong: stale edits require reopening instead of an automatic merge.

4. Task 2: Ruling: Defer requestBoostEditor presentation and its stored UI source to the task that introduces BrowserPanel.boosts — avoids a nonfunctional placeholder method/switch — cost if wrong: no native entry exists until Task4, explicitly incomplete.

5. Task 2: Ruling: Use two native document-start nonces: isolated bridge nonce plus immutable nonconfigurable page-global nonce for the compiled page guard — page JavaScript cannot read isolated globals, while a DOM attribute could be copied/rewritten on a new document — cost if wrong: page-script scope/lifetime guarantees would fail and execution must stay unshipped until real-WebKit regressions pass in Task3.

6. Task 3: Ruling: Keep document execution claims in the isolated document state as well as native state — the back/forward cache can restore a previously executed document after native state switched nonces — cost if wrong: a restored page could run a script twice and duplicate side effects. Added real history restoration coverage; report whether the engine actually retained the document.

7. Task 3: Ruling: Newly saved consent defers automatic execution in every existing profile view until a later provisional navigation (manual Run remains explicit) — an in-flight ready callback must not turn future-load consent into immediate execution — cost if wrong: approval during page load could run code sooner than the user chose. Navigation eligibility must distinguish didStartProvisional from didCommit, and be noted after durable consent before yielding.

8. Task 4: Ruling: No-code colors/fonts/scale save immediately, while unsaved name/site/code edits use Save/Done — closer to Arc's direct customization and still commits before DOM mutation — cost if wrong: Cancel Edit does not undo already-saved appearance choices; the UI must state this and offer Reset Look.

9. Task 4: Ruling: Cache one draft model per store with a weak owner/source; don't retarget a dirty/current editor — prevents panel switches discarding code or redirecting a Quick profile draft into the active Space — cost if wrong: the user must finish/discard one draft before opening another source.

10. Task 4: Ruling: Cancel picker on native session/tab/pane/Peek source changes, not only document navigation — the banner and overlay must not outlive their actual page — cost if wrong: picker mode exits during a workflow and the user must restart it. Owned input regressions will cover these property transitions.

11. Task 4: Ruling: Present JavaScript consent as a documented NSAlert critical sheet on the original source window, with a code icon — a standard sheet would queue behind the open SwiftUI editor and never become usable while editing — cost if wrong: native alert layering/focus may need adjustment after access is restored. Guard other sheets as busy unless this is the matching Boost editor; source/profile/code/lifetime checks are unchanged. Apple source: https://developer.apple.com/documentation/appkit/nsalert/beginsheetmodal(for:completionhandler:) (official search excerpt documents critical alerts above existing sheets; direct page is JS-only and Markdown fetch unsupported by web tool). This is configuration evidence, not live-presentation proof.

12. Final: Ruling: Declined1 live0.7 editor/readability/menu/sheet/prompt/keyboard/color-panel/accessibility — keep these gates open and test the updated same-identity app after source integration; owned bounds cannot prove usable controls — cost if wrong: people may encounter clipped, unfocused or inaccessible editing/approval controls.

13. Final: Ruling: Declined2 live resizing/animation/Arc fidelity — stable0.6.2 smoke evidence does not establish reviewed0.7 visual behavior; retain explicit native gates — cost if wrong: newer layout or animation could remain rough despite green functional checks.

14. Final: Ruling: Declined3 pre-existing quarter-tile footer clipping, missing Space deletion and non-exposed resize splitter — these are confirmed full-goal defects queued for the immediately following increment, not accepted as finished; preserve work/sidebar-native-handoff.txt — cost if wrong: short-window actions stay inaccessible, test Spaces cannot be cleaned up and assistive navigation cannot resize.

15. Final: Ruling: Declined4 broad everyday-site compatibility — fix demonstrated CSS/picker/scaling defects now, retain broader responsive/dynamic corpus QA as incomplete — cost if wrong: untested websites may still resist or react badly to customization.

16. Final: Ruling: Declined5 frames/shadow roots — keep this increment honestly scoped to main-document styling and element picking, with full compatibility scope still open — cost if wrong: framed/shadow content remains uncustomized and may frustrate users expecting the entire site to change.

17. Final: Ruling: Declined6 already-running JavaScript/effects — disabling stops future dispatch; the native deadline only stops waiting and reload may be needed, as documented — cost if wrong: approved code can keep running or leave effects after disable, and a hung page may need closing.

18. Final: Ruling: Declined7 large-catalog latency/memory/browser-speed comparisons — correctness bounds are not performance proof; retain benchmark/long-run gates and no Safari-speed claim — cost if wrong: editing or browsing may be slow or memory-heavy under sustained use.

19. Final: Ruling: Declined8 Intel/minimum-OS/fresh-install/hardware — compiled slices and current ARM probes do not establish target-runtime behavior; retain real-device/install gates — cost if wrong: supported-looking packages may fail on other Macs or fresh installations.

20. Final: Ruling: Declined9 galleries/sync/full-browser features — local Boost sharing does not replace those original requirements; keep them in the active full-goal ledger — cost if wrong: source progress could be mistaken for full Arc parity while major workflows are absent.

21. Final: Ruling: Declined10 trusted signing/notarization/public readiness/CI — retain ad hoc labeling and unchanged public0.6.2; exact-source CI/package inspection follows this fix pass and is not inferred — cost if wrong: downloads could be blocked or an unverified package mistaken for a trusted release.

22. Final: Ruling: Declined11 exhaustive hostile-site/URL-parser security — layered guards and concrete fixture attacks are evidence, not certification; independent audit/adversarial coverage remain open — cost if wrong: an untested isolation or parser edge case could expose user data or run code in an unintended context.

23. Final: Ruling: I1 uses shared structural parsing plus actual nonpersistent WebKit CSSOM retention/property checks before changed CSS may be persisted; an exact-CSS validation receipt prevents synchronous bypass, while empty/unchanged no-code updates stay immediate — replaceSync repairs errors and cannot be treated as validation — cost if wrong: supported-but-unrecognized CSS may require editing, or a validation failure may delay Save; prior saved bytes/styles must stay intact. The helper never adopts the validation sheet, uses default-src none, and touches no profile storage.

24. Final: Ruling: CSS Save/Done/Approve/Zap await validation with frozen draft/profile/content and cancellation generation checks; late Done closes only its own current editor panel — validation is asynchronous and must not overwrite later edits, canceled drafts or another panel — cost if wrong: a pending Save can require retrying, while missing guards could lose newer work. Native input regressions cover edit, cancel and panel switch during actual validation.

25. Final: Ruling: I2 replaces the final author cascade layer with reversible inline-important display state, reconciles new matches/page style updates and restores the latest original value/priority on Undo/off — earlier important layers and inline-important display defeat an appended author layer — cost if wrong: site scripts can observe style-attribute mutations or high-mutation pages can incur extra work; broad dynamic/performance QA remains open. No page/form node is removed or replaced.

26. Final: Ruling: I3 installs generic picker-aware window capture listeners at document start and disables them via inactive picker state on exit; selection still requires a trusted click and Escape still respects composition — suppressing only at the overlay occurs after page capture/pointer activation — cost if wrong: earlier third-party injected listeners may need compatibility work, and live trusted input still requires native QA.

27. Final: Ruling: I4 derives root/rem scaling from the computed site baseline with prior Alcove sheets removed within the same apply call; fixed-pixel descendants are explicitly unchanged — initial-font percentages can shrink a large-font site when increased — cost if wrong: responsive/animated/important-layer font interactions may still need broader site work. Actual10px/24px baselines, repeated75/100/125 percent changes, off and fixed text pass engine checks.

28. Final: Ruling: Run the final check/build commands under process-scoped caffeinate -i — the Mac repeatedly slept during a continuous-clock timing gate, while the unchanged focused suite passes when scheduled — cost if wrong: extra energy during the command, or another real failure will still need investigation; no display wake/unlock/global power preference change occurs. Fresh full/build/probe/bundle chain is live in exec session listed by the current tool response; retain failed evidence and do not restart on observation timeouts.

29. Final: Ruling: Add AC-only PreventSystemSleep for the lifetime of the already-running final gate driver — PreventUserIdleSystemSleep alone did not stop documented maintenance sleeps — cost if wrong: temporary extra AC energy/heat during checks; it neither invokes an unlock/display-wake API nor edits persistent settings. The helper is tied to driver2286 and must be verified released after terminal completion.

30. Final: Ruling: Integrate in the existing main checkout and push under the standing explicit commit/push authorization, without another integration menu or PR — the user already chose in-place/main execution and publication of source changes — cost if wrong: changes become visible on the shared main branch without a separate PR discussion. No public tag/release is created.

31. Final: Ruling: Retain this plan workspace through exact-source CI/package inspection, then archive and remove only it — final CI failures and artifact receipts still need a durable current ledger — cost if wrong: ignored evidence occupies disk somewhat longer; no source or sibling workspace is deleted.
