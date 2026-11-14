# Fullscreen navigation repair verification

Base: f5536e0b30d4ed8803609ad130f05c94243fa9a1, developing branch fix/fullscreen-chrome, dedicated macOS26.6.2 VM. Public v0.9.0-preview.1 and its assets remain unchanged; local candidate packages still carry0.9 and must not be substituted for the published artifacts. The full-browser goal remains active.

## Cause and change
The unchanged native chrome's empty compact toolbar becomes a40pt opaque fullscreen overlay. An owned actual-window experiment changed only toolbar visibility and exposed the same SwiftUI header; contentLayoutRect expanded from760 to800pt. NativeWindowChrome now remembers the exact empty toolbar objects it creates weakly, hides them while the current window is fullscreen and restores visibility on exit. Caller-owned toolbar visibility, native traffic-light ownership, data protection and website subtrees are unchanged.

## Evidence
- Job127: four intended real-fullscreen failures against unchanged chrome; local form, borrowed toolbar and exit-alignment checks passed, no compiler diagnostics. Invalid direct-mask fixture was corrected before production implementation.
- Job128:15/15 actual AppKit fullscreen checks and55/55 existing production ChromeChecks pass; optimized ARM candidate built, no compiler diagnostics. Cases include repeated entry/exit, caller visible/hidden toolbars, returning a reader to its original window, moving it to another window, mounted website preservation and existing weak-window release.
- Live candidate installed only at the established VisualFour test path/identity. Primary, collapsed sidebar and Quick Browse controls are visible and usable in fullscreen; normal traffic-light alignment returns. macOS's temporary top-edge menu overlay still behaves normally.
- Primary unsaved canary/document1776c66a0ac9 survived sidebar/fullscreen changes. Quick unsaved canary/document841c4e8e6601 survived entry/exit. Quick CmdW closed only Quick; main form remained intact. Owned test pages were closed, original HTTPS example.com retained and test app quit. Loopback fixture stopped by exact PID/command match.
- Job132 full frozen package gate passed at2026-11-14T23:30Z:2,420 browser assertions plus1 ZIP check, zero failures/compiler diagnostics. Both optimized architectures and universal app pass strict signatures, runtime/ad-hoc, byte-exact Info, minimum14.0 and exact six entitlements. ZIP/checksums and mounted DMG content/executable matching pass; image detached.186 inputs were unchanged: `ddd3c00d50e2eff924193d5a7b8b7cf30317d8b0270d4bb46007977d3fc66882`.
- One fresh gpt-6-astra/high read-only review found no Critical/Important issues. Its merge condition required the above gate and actual production UI inspection, now fulfilled. This does not constitute a full-browser security audit, physical Intel/minimum-OS/quarantine certification, complete Arc parity or a speed comparison.

## Rulings and costs
1. AppKit rejects setting the fullscreen mask outside a real transition. Use opt-in real native fullscreen tests, without adding desktop control to headless CI. Cost if wrong: live-only failures require an explicit GUI gate and can escape ordinary CI.
2. Visible AppKit windows can remain retained outside chrome ownership. Keep the existing never-shown weak-release assertion rather than require immediate release of a real fullscreen window. Cost if wrong: platform retention can mask a leak; weak window/toolbar ownership remains a review responsibility.
3. Remember created toolbar identity weakly across reattachment so returning to the original window works. Cost if wrong: externally repurposing that exact empty toolbar can retain its chrome classification; unrelated caller objects are not claimed.
4. Reviewer declined full Arc/browser completeness: retain the entire acceptance ledger and active goal. Cost if wrong: users could mistake a repaired preview for a completed browser; no such claim is made.
5. Reviewer declined legacy CtrlCmdF compatibility: native menu/FnF and green-button fullscreen remain; legacy shortcut work is separate. Cost if wrong: users relying on that older shortcut remain surprised.
6. Reviewer declined unchanged extension/persistence/release behavior: full regression/package checks still apply, without claiming a new independent audit. Cost if wrong: pre-existing defects outside this narrow diff can remain.

## Deferred minor
M1: the automated form fixture asserts its initial HTML value, which an identical-document reload could restore. No reload path was introduced/found. A later test task should set a distinct post-load unsaved value and document token. The actual primary and Quick UI checks above used unsaved typed text and per-request tokens and passed. Per the one-review process, this minor was recorded rather than starting another implementation/review cycle.

## Separate next work
Unmodified public0.9 reproducibly fails programmatic Quick address focus through CmdL, File/Open Location and the blank-page button; clicking the field works. An owned actual-input diagnostic reproduces editing ending after makeFirstResponder/selection; investigation continues separately. Actual OS Reduce Motion/VoiceOver, broader accessibility/native fidelity, multiple normal windows, richer splits/media/capture, sync and all remaining feature/security/performance gates stay open.
