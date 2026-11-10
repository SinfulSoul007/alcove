# Sidebar viewport and accessibility verification

Source increment: 0.7.1/build13, candidate v0.7.1-preview.1; baseline 903655397c2ec1ef23492ab5de4c588bd9767cb9. No public release/tag and no replacement of the running Visual Four app.

The actual BrowserUI root now fills its received viewport instead of imposing an internal 800×540 canvas. The normal NSWindow minimum stays unchanged. The native divider exposes its width/range, numeric setter, increment/decrement, Reset Sidebar Width and actual responder focus. A dedicated keyboard-focus hold retains a floating sidebar until focus is released. Overlay/hide/close/detach cancellation protects saved width.

## Evidence

- Corrected viewport regression: 16 PASS/8 FAIL before the fix; 24 PASS/0 FAIL after it. The native footer popup was at y=-28 in a 960×494 viewport, and y=-122 in 760×400. Native borderless popup cells are14pt high; the initial test incorrectly required16pt and was corrected before accepting RED.
- AX/root regressions: 33 PASS/16 FAIL before the divider implementation. Final mounted-root suite:49 PASS/0 FAIL. Includes real form/scroll preservation, short/crowded/large-text layouts, synchronous AX steps, live native bounds, clamping/invalid values, actual focus, stale overlay actions, floating focus retention/release and closed/detached rejection.
- Follow-up delayed-focus regression:48 PASS/1 FAIL before rejecting stale focus callbacks while disabled. Final native sidebar suite:50 PASS/0 FAIL, retaining original mouse, cancellation, window and tracking assertions.
- Existing browser chrome suite:55 PASS/0 FAIL. All focused checks have zero compiler diagnostics.
- Optimized arm64 and x86_64 bundles pass strict signature, Hardened Runtime, byte-identical Info, exact architecture, minimum macOS14 and unchanged exact six-entitlement gates. Their receipts are retained with the plan evidence.
- Full local suite, final fresh review and exact-source CI/package checks are pending at this checkpoint.

## Rulings and costs

1. Work in existing main checkout under standing authorization, without another worktree/approval gate. Cost if wrong: shared checkout changes lack branch isolation.
2. Reuse exact9036553 local/CI1,392-pass baseline; run new RED checks and the final complete suite. Cost if wrong: environmental changes are caught only by the new/final runs.
3. Keep root layout and native divider in one coupled sidebar task with separate RED→GREEN substeps. Cost if wrong: a larger review unit than separate component tasks.
4. Use process-scoped caffeinate -is after the documented prior sleep interruption; change no system power/security preferences. Cost if wrong: temporary AC power use lasts until verification exits.
5. Absolute AX/arrow commits share one path; the raw fixture binds that setter and uses the1000pt viewport its drag callback assumes. Cost if wrong: arrow commits no longer call mouse begin/end hooks.
6. Dynamic root canInteract supplements the rendered enabled flag so a new overlay immediately rejects stale actions. Cost if wrong: AppKit input synchronously consults observable/controller state.
7. Treat review/distribution as post-task whole-plan workflow, with implementation completion recording its full test gate first. Cost if wrong: these workflow steps are reported separately from task1 completion.

## Remaining full-goal gates

The installed Alcove Visual Four is still0.6.2/build9/dev.openbrowser.mac.visual4. Computer Use reports the Mac locked; live sidebar/animation/VoiceOver/focus-ring and current-source Arc comparison are unverified. Hidden owned windows prove geometry/input only. No Safari speed, independently audited security, trusted signing, real Intel/macOS14 hardware or quarantined installation claim is made.

Space management/deletion remains missing (including the empty Sidebar Test Space from native QA). Boost minor M1 Copy Appearance after Unhide remains deferred. All broader original browser requirements in acceptance.md remain active, including richer tabs/splits, media, permissions/downloads/import/reader, extensions, sync, Easels/capture and assisted workflows.
