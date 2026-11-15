# Quick Browse address-focus repair

Base: `6b0a495b848ac0f0e971c0e0db0f148b712cda2a`. Dedicated macOS26.6.2 ARM64 VM, isolated `fix/quick-address-focus` worktree. This record concerns the native field repair and separately prepared0.9.1/build17 metadata. The full-browser acceptance ledger remains active.

## Cause and behavior

The unchanged public0.9 Quick window becomes key correctly, but programmatic address selection calls `makeFirstResponder` followed by the control's `selectText`. The second operation ends editing and triggers the legitimate cancellation path. CmdL, File/Open Location and the blank-page address button therefore fail even though clicking the field works.

The repaired field reuses its current native text editor, makes one responder transition only when necessary, and selects within that editor. Existing own-window, key-window, enabled and pending-request guards remain. Genuine end-edit cancellation and durable metadata APIs are unchanged.

## Evidence

- Owned probes133/135 distinguish activation from selection reentry; probe136 validates reuse across automatic, repeated and post-blur requests. Disposable133/135 harnesses had one unused-result warning; final production/test gates have none.
- Actual-controller regression137 failed eight intended assertions and passed eight others before the production change. Fixture-ready and finished markers are present. Regression138 passes16 focus checks,16 existing native lifecycle checks and55 chrome checks:87 total, zero failures/compiler diagnostics. Earlier internal17/15 splits and RED-nine-pass notes were bookkeeping errors; these are the corrected source-log counts.
- Focus tests use private stores and owned HTML, with no real profile, Keychain or network. They verify initial/repeated URL and Find selection, background/pending/closed-window ownership, a post-load unsaved value and per-request document token, the same mounted WKWebView and release.
- The optimized VisualFour candidate passed live automatic focus, repeated CmdL, File/Open Location, blank-page refocus after Escape, address typing/navigation, native URL Copy, Unicode paste, repeated Find, Escape/blur, a second Quick window closing independently and fullscreen focus. Unsaved `KEEP-QUICK-6127` and document `491d26e00731` survived, including fullscreen exit. Generated windows were closed, the app quit and the owned loopback server stopped by exact PID/command matching. Existing HTTPS primary content remained.
- One fresh independent gpt-6-astra/high read-only review of five pinned inputs found no Critical, Important or Minor code findings. Its live and full-package conditions are addressed here; the unchanged patch was not sent for another review.
- Job143 full package gate completed2026-11-15T05:55:56Z:2,420 browser assertions plus1 ZIP verifier assertion, zero failures/compiler diagnostics. Both optimized architectures and universal app passed strict signatures, runtime/ad-hoc, exact source Info, minimum14.0 and six entitlements. Checksums, ZIP extraction and mounted-DMG executable/Info/read-me/Applications-link readback passed; image detached.187 frozen inputs stayed unchanged, fingerprint`64784ad9bcb1f8f2135c1cc3bc62d93e304d5bd5e1ee8cce6be1eaadd3e3f212`. Source CI and public publication remain separate subsequent gates.
- Bundle version0.9.1/build17/tag`v0.9.1-preview.1`, production identity`dev.openbrowser.mac`, minimum macOS14.0 and encrypted metadata format5. Release-workflow edits are human-facing notes only; workflow permissions, executable actions, publishing commands and tag guards remain unchanged.

## Review rulings and costs

1. Prior fullscreen work is outside this focus review. Retain its separate completed review/local package and successful exact-source CI43653941257 at6b0a495 (2,423 browser plus2 ZIP assertions). Cost if wrong: cross-feature behavior can escape the narrow review; the actual combined fullscreen/field live check passed. Its existing deferred automated-fixture-strengthening minor remains recorded separately.
2. Release version, tag, signing, CI and public download-back are separate gates. This source review does not approve an untested publication. Cost if wrong: readers could mistake a tested source patch for a verified public installer. Public verification is recorded separately; previous0.9 assets/tag stay immutable.
3. Full browser/Arc completion is outside this repair. Retain all acceptance requirements. Cost if wrong: a narrow patch could be mistaken for complete parity; sync, multiple normal windows, deeper splits, media, capture, accessibility, performance and other browser work remain open.
4. Runtime IME, clipboard and accessibility were not independently executed by the reviewer. Basic native URL Copy and Unicode paste subsequently passed live; actual IME and VoiceOver remain open, and delegate marked-text handling was unchanged. Cost if wrong: an untested input method or assistive workflow can still reveal defects.
5. Native-window regression commands are explicit opt-ins (`quick-focus-test`, existing`quick-native-test`, `chrome-fullscreen-test`); they are not added to headless CI. Cost if wrong: desktop-only regressions require the explicit VM/native gate, rather than being silently treated as ordinary CI coverage.
6. Keep Keychain protection and the existing six entitlements. Changed ad hoc signed code can require native approval; the dedicated VM prompts were completed normally without plaintext fallback or broad ACL changes. Cost if wrong: unsigned upgrade friction remains until trusted signing is available.

## Boundaries

Both architecture compilation and universal/package verification do not establish physical Intel, macOS14, quarantined installation, full extension compatibility, an independent security audit or Safari-equivalent speed. Full uBlock Origin remains unsupported; separate uBlock Origin Lite has limited tested compatibility. The opening greeting is independent of this patch and remains included. The actual captured-frame welcome preview has approximate playback timing and is not performance evidence. Continuous runtime OS Reduce Motion/VoiceOver verification remains open.

Native motion follow-up: OS Reduce Motion was enabled through System Settings; unmodified public0.9 restored its saved HTTPS/theme without a new Keychain prompt, and welcome replay reached setup. Native video capture exited1 with no MOV/diagnostics, so continuous-transition coverage is not claimed. Motion was restoredOFF and visually confirmed, replay skipped back to the unchanged page and app quit.
