# Native Page Output Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Print or save the actual visible browser document through native, window-owned user actions.

**Architecture:** A PageOutputCoordinator captures and validates one job per window. An injected environment supplies only WebKit capture, native print/save presentation and asynchronous file writing. A separate native adapter owns panel/print-delegate lifetimes. BrowserStore supplies visibility without key-window timing, while AppDelegate resolves owned window targets and registers actions.

**Tech Stack:** Swift, AppKit, WebKit, UniformTypeIdentifiers and PDFKit in checks; macOS14 minimum.

**Spec:** `docs/superpowers/specs/2026-11-08-page-output-design.md`

## Global constraints

- Preserve macOS14, metadata format3, current profiles/themes, unsigned labels and Command-S sidebar toggle.
- No dependencies, private APIs, global input synthesis or real user/session/Keychain data in fixtures.
- Add only the printing entitlement; exports require explicit destinations and remain outside metadata encryption.
- One job per window; preparation deadline30 seconds; unique generation identity across all callbacks.
- Before destination acceptance, changed page/profile/window ownership and cancellation write nothing. After acceptance, atomic background IO may finish when its window closes.
- Keep live native sheets/printer, minimum-OS/Intel, saved-archive reopening, website-initiated printing and full-goal gates explicit.

## Review focus

- Captured page/profile/Peek replacement while WebKit or a picker is pending cannot export a different account or resurrect a cancelled job.
- Synchronous and repeated backend callbacks cannot assign a stale cancellation handle, write twice or clear a new job.
- Sheet completion may precede native key-window restoration; valid confirmation works without accepting a background start.
- Close, failure and preparation timeout release jobs/presentations without a user-app operation or an indefinite busy window.
- File output already accepted may finish after close, but stale errors/messages cannot appear on a different page/profile/window.

### Task 1: Owned output coordinator and native adapter

**Files:**
- Create `Sources/Browser/PageOutput.swift` and `Sources/Browser/PageOutputNative.swift`.
- Modify `Sources/Browser/QuickBrowseActions.swift`.
- Create `scripts/PageOutputChecks.swift`; modify `scripts/build.sh`.

**Interfaces:**
- Consumes existing `profileID(for:)`, `profileUnavailable(_:)`, Peek/current view ownership and window identity.
- Produces `PageOutputFormat.pdf/.webArchive` with `suggestedName(_ title: String?) -> String` and content type/extension.
- Produces `BrowserStore.isVisibleWebsite(_ web: WKWebView) -> Bool`; `isFocusedWebsite` adds key/sheet focus to that same policy.
- Produces `PageOutputEnvironment` with capture `(WKWebView, PageOutputFormat, @escaping (Result<Data, Error>) -> Void) -> Void`, choose `(NSWindow, String, PageOutputFormat, @escaping (URL?) -> Void) -> (() -> Void)`, print `(WKWebView, NSWindow, @escaping (Bool) -> Void) -> (() -> Void)` and write `(Data, URL, @escaping (Result<Void, Error>) -> Void) -> Void`; `.live` uses the native adapter.
- Produces `PageOutputCoordinator(environment: PageOutputEnvironment? = nil, preparationTimeout: Duration = .seconds(30))`, `canBegin(web:store:window:) -> Bool`, `save(web:store:window:format:)`, `printPage(web:store:window:)`, `cancel(in: NSWindow)` and `isBusy(in: NSWindow) -> Bool`.

- [ ] **Step 1:** Write owned-fixture behavioral checks first: print/capture receives the visible view/window; background/covered/paused/unowned starts fail; two windows remain independent; cancel/close/URL/profile/view replacement during preparation/picker creates no file; duplicate/synchronous callbacks cannot double-write or clear a new job; timeout releases busy state; accepted IO may finish after close without stale UI; empty/unsafe/Unicode names remain valid leaf filenames. Use literal expected temporary file bytes; replace only native presentation/capture timing where required.
- [ ] **Step 2:** Add `scripts/build.sh page-output-test`, compile the real store/coordinator and checks, and run it. Expected: missing new interfaces or output behavior failures before implementation; save RED evidence.
- [ ] **Step 3:** Implement the coordinator and live native adapter. Use weak ownership/token/stage checks, anchored preparation deadline, per-window print sheets, retained native completion delegates, save type restrictions and atomic background writes with selected-URL scope. Do not add an app-modal loop or JavaScript print bridge. Preserve existing focused-page permission behavior while extracting visibility.
- [ ] **Step 4:** Run `scripts/build.sh page-output-test` and existing Quick Browse native checks. Expected: all focused behavior/lifecycle checks pass without diagnostics. Commit, then task-done records the focused command on the committed source.

### Task 2: Menus, real WebKit output and distribution policy

**Files:**
- Modify `Sources/Browser/BrowserAppDelegate.swift`, `scripts/Entitlements.plist`, `scripts/Info.plist`, `scripts/PageOutputChecks.swift`, `scripts/build.sh`, README, SECURITY and acceptance/report docs.
- Create `scripts/PageOutputWebsiteChecks.swift` if separate SDK capture checks improve the focused route.

**Interfaces:**
- Consumes Task1's format, coordinator, environment and visible/focused ownership policy.
- Produces `PageOutputCommand.printPage/.pdf/.webArchive`, `AppDelegate.outputTarget(in: NSWindow?) -> (store: BrowserStore, web: WKWebView, window: NSWindow)?`, and `performPageOutput(_ command: PageOutputCommand, in: NSWindow?)` used by selectors and owned-fixture checks. AppDelegate holds `pageOutput` and cancels it on window close.

- [ ] **Step 1:** Add failing checks for actual File-menu selector/shortcut registrations and target resolution across main/split/Peek/Quick/private and unrelated/nil windows. Add actual WebKit PDF text/WebArchive resource verification, cancellation at the native-choice boundary and independent document markers. The print factory creates a real operation without showing it; no printer/device is used. Run focused checks before wiring; expected missing menus/routing or empty/missing outputs.
- [ ] **Step 2:** Wire Print… Command-P, Export as PDF… and Save Page As… Command-Shift-S; validate via actual window/visible target and busy policy. Keep Command-S unchanged. Add only `com.apple.security.print=true`; move developing identity to0.6.2-preview.1/build9. Update privacy copy and list remaining archive-opening/website-print/native gates accurately.
- [ ] **Step 3:** Run focused output, actual WebKit and existing Quick Browse/media-ownership checks. Expected: correct document content and destinations, no private normal-metadata writes or ownership regressions. Run complete `scripts/build.sh test` and optimized arm64/x86_64 builds once on final production sources; verify each signature/Info/architecture and exact six-entitlement set. Record diagnostics/results and commit the task.

After both tasks, dispatch one fresh whole-branch reviewer under executing-plans. Grade findings by user effect; one RED→GREEN fix pass for Important/Critical findings, full suite after that pass, no second reviewer. Preserve every ruling/deferred minor and remaining full-goal gate before cleanup and push under existing authorization. Do not overwrite public0.6.1 assets or claim a new download before its release gates pass.
