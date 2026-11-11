# Sidebar viewport and accessibility verification

Verified product source: [c499631](https://github.com/SinfulSoul007/alcove/commit/c49963160398b6c2ccd28acce39811698d380717). Complete local suite:1,463 PASS/0 FAIL/0 compiler diagnostics. [Exact-source CI42943318357](https://github.com/SinfulSoul007/alcove/actions/runs/42943318357) passes1,463 browser plus2 ZIP checks. The downloaded universal DMG/ZIP and mounted contents pass all recorded gates. Later pending statements below are historical checkpoints, superseded by this result. Final documentation is a separate commit with unchanged114-file product/test inputs.

Source increment: 0.7.1/build13, candidate v0.7.1-preview.1; baseline 903655397c2ec1ef23492ab5de4c588bd9767cb9. No public release/tag. The existing Visual Four app was updated in place after CUA-confirmed Quit, retaining its path/bundle ID/display name; prior bundles were preserved.

The actual BrowserUI root now fills its received viewport instead of imposing an internal 800×540 canvas. The normal NSWindow minimum stays unchanged. The native divider exposes its width/range, numeric setter, increment/decrement, Reset Sidebar Width and actual responder focus. A dedicated keyboard-focus hold retains a floating sidebar until focus is released. Overlay/hide/close/detach cancellation protects saved width.

## Evidence

- Corrected viewport regression: 16 PASS/8 FAIL before the fix; 24 PASS/0 FAIL after it. The native footer popup was at y=-28 in a 960×494 viewport, and y=-122 in 760×400. Native borderless popup cells are14pt high; the initial test incorrectly required16pt and was corrected before accepting RED.
- AX/root regressions: 33 PASS/16 FAIL before the divider implementation. Final mounted-root suite:49 PASS/0 FAIL. Includes real form/scroll preservation, short/crowded/large-text layouts, synchronous AX steps, live native bounds, clamping/invalid values, actual focus, stale overlay actions, floating focus retention/release and closed/detached rejection.
- Follow-up delayed-focus regression:48 PASS/1 FAIL before rejecting stale focus callbacks while disabled. Final native sidebar suite:50 PASS/0 FAIL, retaining original mouse, cancellation, window and tracking assertions.
- Existing browser chrome suite:55 PASS/0 FAIL. All focused checks have zero compiler diagnostics.
- Optimized arm64 and x86_64 bundles pass strict signature, Hardened Runtime, byte-identical Info, exact architecture, minimum macOS14 and unchanged exact six-entitlement gates. Their receipts are retained with the plan evidence.
- Pre-review complete local suite:1,445 PASS/0 FAIL/0 compiler diagnostics. One fresh whole-plan review found Important I1 native-modal input blocking and Minor Sidebar M1 floating-matrix coverage. The single fix pass reproduced/fixed I1; live QA then reproduced/fixed Important N1 empty-root Tab focus retention. Final suites pass62 mounted-root,54 native interaction and55 chrome checks; the complete final suite passes1,462/0 failures/0 compiler diagnostics, terminal0. Both final optimized bundles pass all recorded gates. The final114-file source manifest stayed unchanged before/after the serialized gate. No second reviewer. Exact-source CI/package remains pending at this checkpoint.

## Rulings and costs

1. Work in existing main checkout under standing authorization, without another worktree/approval gate. Cost if wrong: shared checkout changes lack branch isolation.
2. Reuse exact9036553 local/CI1,392-pass baseline; run new RED checks and the final complete suite. Cost if wrong: environmental changes are caught only by the new/final runs.
3. Keep root layout and native divider in one coupled sidebar task with separate RED→GREEN substeps. Cost if wrong: a larger review unit than separate component tasks.
4. Use process-scoped caffeinate -is after the documented prior sleep interruption; change no system power/security preferences. Cost if wrong: temporary AC power use lasts until verification exits.
5. Absolute AX/arrow commits share one path; the raw fixture binds that setter and uses the1000pt viewport its drag callback assumes. Cost if wrong: arrow commits no longer call mouse begin/end hooks.
6. Dynamic root canInteract supplements the rendered enabled flag so a new overlay immediately rejects stale actions. Cost if wrong: AppKit input synchronously consults observable/controller state.
7. Treat review/distribution as post-task whole-plan workflow, with implementation completion recording its full test gate first. Cost if wrong: these workflow steps are reported separately from task1 completion.

## Final review, native QA and failed/intermediate checks

I1 corrected RED:51 PASS/11 FAIL; GREEN:62 PASS. Native sheets and other app-modal windows now synchronously disable commands/refocus, and willBeginSheet cancels an active drag/focus hold without relying on key resignation. N1 RED:50 PASS/2 FAIL; GREEN:54 PASS. Ordinary Tab/back-Tab uses native traversal, then releases focus only if it returned to the same divider; available native text-field destinations remain intact.

The initial modality harness used direct NSApplication construction and exited133/Trace-BPT before assertions; it was corrected to the shared subclass singleton and not counted as behavioral RED. A subsequent full run consumed an in-progress Tab test edit and ended912 PASS/2 FAIL. An attempted stop had reached only its caffeinate helper, not its command parent; that mixed-source run is not final verification. Both sessions were confirmed terminal before the final serialized driver, which checks the frozen source before/after and passes1,462/0/0.

Live0.7.1/build13 QA exposed the new splitter through the OS AX tree. Numeric260, Right272, Left260 and custom Reset236 worked; mouse drag236→276 worked. Bottom-edge window shrink retained visible footer controls, then height/width were restored. The focus ring rendered; hiding a focused sidebar cleared focus. On the final N1 build, Tab and Shift-Tab now move from the divider to the standard window on an empty page. No private browsing data was used as a fixture. Pure hover/floating and later native quarter tiling remain unverified: edge-click attempts did not establish hover, and native menu automation produced invalid/ambiguous element references; the user confirmed dismissing that menu.

A re-signed preview startup then waited on macOS Keychain. A read-only owned-process sample located the main-thread wait in BrowserStore.init→MetadataKey.load→SecItemCopyMatching. The user confirmed and completed the visible macOS prompt; the same process immediately became accessible again. No password was requested in chat and no Keychain/Gatekeeper protection changed. Responsive Keychain startup is a new outstanding full-goal defect.

Additional final rulings, in chronological order (these supplement1–7 above):
8. D1 live VoiceOver/external AX under real modal UI — remain unverified, owned methods are narrower — cost if wrong: actual assistive-tech integration may differ.
9. D2 composited ring/motion/tiling/Arc fidelity — user has now unlocked, perform live current-build QA without certifying all fidelity — cost if wrong: unobserved visual defects remain.
10. D3 mounted-root Tab order — retain native traversal probe as narrow evidence; live root traversal remains to check — cost if wrong: production navigation order may differ from adjacent-field probe.
11. D4 focus on other sidebar controls — remains broader accessibility work, divider hold does not prove global parity — cost if wrong: another focused control may hide with the panel.
12. D5 viewport changes during a mouse gesture — no reproduced defect; existing captured-geometry path stands for this increment, retain native concurrency QA — cost if wrong: stale mouse bounds may allow an incorrect commit.
13. D6 retained custom action after same Handle reattachment — actions intentionally address its current live attachment; no demonstrated OS old-window binding sequence — cost if wrong: an old client reference could resize the new window.
14. D7 smaller/unusual viewports and all banners — tested bounds do not certify arbitrary sizes or combinations; retain broader visual gate — cost if wrong: untested combinations may clip.
15. D8 Space management — still missing; next coherent feature, not waived — cost if wrong: leftover test Space and management gaps persist meanwhile.
16. D9 Boost minor and site behavior — preserve separate deferred Boost M1 and site/native QA; untouched source stands — cost if wrong: known Copy Appearance mismatch remains until its own task.
17. D10 full browser features — all stay in original acceptance scope, no parity claim from sidebar work — cost if wrong: remaining browser scope takes further work.
18. D11 Safari performance/site reliability/security audit — remain unproven with explicit measured/audited gates — cost if wrong: users may encounter compatibility or resource/security issues.
19. D12 hardware/quarantine/signing/update trust/native output — structural builds do not certify these; retain original gates and unsigned labeling — cost if wrong: real-device/install/native behavior can differ.
20. D13 CI/artifacts/publication — finish exact-source CI/download-back; no public0.7.1 release in this unit, update same-identity test app now authorized/unlocked — cost if wrong: public0.6.2 stays behind source features until later publication.
21. D14 missing floating matrix behavior — M1 remains a deferred coverage gap, not proof of failure — cost if wrong: untested empty/text1 floating cases may regress.
22. D3 regraded after live QA as Important N1 — empty BrowserUI has no alternate valid key view, and Tab/Shift-Tab/Escape stayed on the focused divider (unlike review's linked-field probe). Add a fallback focus release when ordinary Tab traversal returns to the same divider, retaining normal traversal when another view exists — cost if wrong: Tab can clear focus rather than land on a control when AppKit supplies no alternate destination.
23. Treat synchronous Keychain startup blocking as the next independent full-goal defect — actual sample/user prompt prove a broader startup problem unrelated to sidebar code; retain source/native recovery work after this unit rather than weaken Keychain permissions — cost if wrong: re-signed previews can still wait on a macOS prompt until responsive startup is implemented.

24. Fix CI readiness in the owned fixture only and run full local/remote gates on frozen source; the exact log and delayed-DOM reproduction identify a harness race. Cost if wrong: the fixture may still time out or race; packaging remains gated on new CI.

25. Record final documentation with `[skip ci]`, retaining exact verified product source c499631 and identical114-file inputs; this avoids a full build just to record its completed evidence. Cost if wrong: the later docs-only HEAD has no separate CI run; artifact provenance remains the verified product commit. This uses GitHub’s documented [workflow-skip mechanism](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/skip-workflow-runs).

Deferred minors: Sidebar M1 floating-layout automated coverage only includes crowded Favorites/text1.35; empty/text1 floating combinations remain to cover. Separately retained Boost M1 Copy Appearance after Unhide can carry stale selectors.

## Remaining full-goal gates

The installed Alcove Visual Four is now0.7.1/build13/dev.openbrowser.mac.visual4. Its owned/source/native checks above are bounded evidence; live VoiceOver/rotor order, full floating/animation/fidelity, current-source Arc comparison and remaining native output/device behavior are unverified. Hidden windows do not establish composited smoothness. No Safari speed, independently audited security, trusted signing, real Intel/macOS14 hardware or quarantined installation claim is made.

Space management/deletion remains missing (including the empty Sidebar Test Space from native QA). Boost minor M1 Copy Appearance after Unhide remains deferred. All broader original browser requirements in acceptance.md remain active, including richer tabs/splits, media, permissions/downloads/import/reader, extensions, sync, Easels/capture and assisted workflows.


## CI readiness correction checkpoint

CI42941134404 at50f241e failed/exit133 after the54 native checks passed: the owned input was still absent when the layout harness tried to set its value. No download artifact was produced. A delayed-load fixture reproduced this locally as an explicit readiness failure (0 PASS/1 FAIL); a10s actual-DOM/document-readiness poll now passes63 focused checks with zero diagnostics. Production Sources/Info/Entitlements/Icon are byte-identical to the previously verified optimized/native bundles. The new complete local suite and exact-source CI/package are pending at this checkpoint; prior1,462-pass evidence is retained as its historical checkpoint.

## Verified downloadable package

CI artifact13822457161:8,054,737 bytes; outer SHA256 `31bc8a3e1b8fe4ac01824484a956f843fb92610711e22c1bd2dc786bddcf427c`. GitHub artifact retention is14 days; local output copies are retained. No new public release/tag was created; public0.6.2 remains unchanged.

- `Alcove-0.7.1-universal-unsigned-preview.dmg`: 4,421,019 bytes; SHA256 `bdd84ead20d3c483047b624747f1779ca06973f0ef78838ba4a405bcd65187ab`.
- `Alcove-0.7.1-universal-unsigned-preview.zip`: 3,668,027 bytes; SHA256 `ba1af59a26c924e462522458b62912780918230468405c0fdaf6a11bc408e6fe`.

The universal executable SHA256 is `fe4493100edfbbebcce16730e640202d03352c36bb5ed7a4fb5242d4be183264`. Both architecture slices pass strict signature/Hardened Runtime/exact-six-entitlement/minimum14 checks; Info and license match source. ZIP and mounted DMG executable/Info/license agree; the DMG has its Applications link and README and was detached. Preview remains ad hoc signed, not Developer ID signed/notarized. CI’s Node20→24/deprecation/capacity notices are retained as noncompiler notices; compiler diagnostics are zero.

This scoped sidebar plan is complete. The original full-browser objective remains active, with responsive Keychain startup next, then Space management and the full acceptance inventory. No full Arc parity, Safari speed or independent security-audit claim is made.
