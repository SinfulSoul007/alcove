# Native Easel Editor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Give Alcove native canvas tabs with editable notes, links, images and source-bound page captures.

**Architecture:** Native routes resolve through profile-scoped catalogs and document transactions. A retained draft coordinator separates immediate text input from durable saves; AppKit supplies the canvas and text editing. Image import, capture and export use existing ownership/output lifecycles.

**Tech Stack:** Swift, SwiftUI/AppKit, WebKit public APIs, ImageIO, CryptoKit; macOS 14+.

**Spec:** `docs/superpowers/specs/2026-11-26-easel-editor-design.md`

## Global Constraints

- macOS 14 minimum; no new dependency, key provider, Keychain policy or WebKit privilege.
- Normal assets consume the unlocked metadata key and matching root lease. Private mode never reads normal files or requests a key.
- Native routes never register a WebKit/extension page and never broaden external scheme handling.
- Draft debounce 250 ms; native text/IME/undo work normally; failed saves retain drafts and cancel destructive closure.
- Magnification 0.25...2.0; item geometry/content limits are those enforced by `Easel`.
- PNG exports content bounds plus48-point margin, default2×, at most8192 pixels/side and16 million pixels total. Empty canvas960×640 points; decoded cache96MiB.
- All capture/import completions are bound to the original profile, document and presentation; stale completions cannot publish.
- Editor completion does not imply cloud sharing, drawing tools, Live Captures or whole-browser completion.

## Review Focus

1. A route restored or moved under another profile must not read the original canvas — Task 1 ownership tests.
2. An editor unmounted or closed during a failed/stale save must keep its text — Task 2 draft/closure tests.
3. Native canvas repainting must preserve text focus and geometry gestures without layout loops — Task 3 real-view reconciliation tests and VM checks.
4. A late import/capture callback after profile retirement must not recreate deleted content — Task 4 source-lifetime tests.
5. Exporting adversarial note/link/image data must remain offline and inert — Task 5 real export roundtrip checks.

### Task 1: Profile-scoped native tabs and edit transactions

**Files:** create `Sources/BrowserCore/EaselRoute.swift`, `Sources/Browser/EaselActions.swift`, `scripts/EaselTabChecks.swift`, `scripts/EaselRouteChecks.swift`; modify `Sources/Browser/BrowserWindowPages.swift`, `Sources/Browser/BrowserStore.swift`, `scripts/build.sh`.

**Interfaces:** `EaselRoute(id: UUID)`, `EaselRoute.parse(_ text: String) -> EaselRoute?`, `route.url: URL`, `EaselRoute.isNative(_ text: String) -> Bool`; `EaselTabContext(tabID: UUID, profileID: UUID, easel: Easel)`; `BrowserStore.easelContext(for tabID: UUID) -> EaselTabContext?`; `createEasel(title: String = "Untitled Easel", in spaceID: UUID? = nil) throws -> UUID` returns its tab ID; `openEasel(_ id: UUID, in spaceID: UUID? = nil) throws -> UUID`; `editEasel(in tabID: UUID, expectedRevision: UUID, edits: [EaselEdit], at: Date = Date()) throws -> Easel`.

- [x] Write route parsing tests first; exact canonical roundtrip, case handling, malformed identifiers and every rejected URL component. Expected: missing API on baseline compile. Implement the narrow parser without changing `Address.resolve`.
- [x] Write real store tests first: atomic create/open/reuse, persistent pinned route and relaunch; normal/private profile isolation including matching foreign UUIDs; no key/disk in private; native routes never appear in registered WebKit maps; unavailable profiles and unowned window presentations reject edits; revision/batch/save failure leaves model and ciphertext unchanged; rename updates only the owning profile's tab titles. Expected: missing API, then runtime failures until implemented.
- [x] Implement candidate-copy catalog/tab transactions using `requireManagedSpace`, `makeDocument`, `setLibrary` and `commitQuickDocument`/`commitProfileDocument`. Do not wire creation UI until a native renderer exists. Guard native routes in `primaryPageView` and the WebKit factory (defensive callers get an unregistered, extension-free nonpersistent blank view).
- [x] Integrate `ALCOVE_EASEL_ROUTES_ONLY=1 scripts/build.sh` and `scripts/build.sh easel-tab-test` into default checks. Compile native tests on host; run them only in dedicated VM/CI. Expected: all route/store checks pass, including private zero-key/zero-file and failed-save rollback. Run existing core/window/sidebar regressions and warnings-as-errors compilation.
- [x] Commit and record task-done with the route runner plus VM store-result evidence; preserve the existing full-suite checkpoint run 45918558575.

### Task 2: Retained text drafts and close safety

**Files:** create `Sources/Browser/EaselDrafts.swift`, `scripts/EaselDraftChecks.swift`; modify store/tab/window/quit lifecycle entry points.

**Interfaces:** main-actor `EaselDraftCoordinator` owned by the metadata/private-group writer; draft key is profile/board/tab/item, distinguishing independent editors and surviving view unmount. `update(_ text: String, tabID: UUID, itemID: UUID, from source: BrowserStore) throws` captures original content/revision and actual presenter; `flush(tabID: UUID) throws`, `flushAll() throws`, `discard(_ key: EaselDraftKey)` and `saveAsNewNote(_ key: EaselDraftKey) throws -> UUID` provide explicit recovery. Rebase only if the latest item content still equals the captured original; otherwise keep both texts and require Copy/Save as New Note/Discard. It consumes Task 1 `editEasel` and never overwrites a stale revision. Dirty state stays retained while its view is unmounted. Register/unregister native editor attachments without retaining NSViews.

- [x] Write real store/draft tests: debounce, flush-before-action, typing/IME byte bounds, two-editor conflict, unmount retention, failing metadata save, close/window/quit cancellation, explicit discard, and clear/delete/shutdown invalidation. Expected: missing API/behavior failures.
- [x] Implement draft retention and synchronous flush hooks before destructive actions; native error UI offers retry or explicit discard, preserving the entire draft. Expected: no closure or stale callback silently loses text; private drafts use zero key/files.
- [x] Run VM draft plus existing tab/window/quit/metadata ownership checks. Expected: all pass. Commit and task-done with recorded commands/results.

### Task 3: Native canvas and Library entry points

**Files:** create focused `EaselCanvasView.swift`, `EaselCardView.swift`, `EaselCanvasActions.swift`, `EaselLibraryView.swift` and native view checks; modify browser pane, commands, menu, sidebar creation and Library sections.

**Interfaces:** `EaselPane(store: BrowserStore, tabID: UUID)` consumes Task 1 context and Task 2 drafts. Stable `NSScrollView`/document view reconciles cards by item UUID; gesture previews commit one edit batch at completion. Draft coordinator owns text. Library resolves current-profile catalog only.

- [x] Write real view tests for stable node/text focus, drag/resize clamp and single commit, safe key routing, layering, stale gestures, undo/redo, magnification limits and reduced motion. Expected: missing view/behavior failures.
- [x] Implement themed canvas, notes and links with labeled accessible controls, keyboard movement/delete, layer actions, native undo, zoom/reset/fit. Add New Easel and Library collection entry points once rendering works. Expected: create/open/edit/close/reopen usable in normal/private windows; pins/folders and split presentation remain correct.
- [x] Run tests and live VM input/resize/appearance acceptance, with no extra QA windows left open. Expected: same text and canvas survive redraws and relaunch; no layout cycles or focus theft. Commit and task-done.

### Task 4: Images, page capture and profile erasure

**Files:** create `EaselImageImport.swift`, `EaselCapture.swift`, image/source-lifetime checks; extend store asset lifecycle and existing profile clear/delete operations.

**Interfaces:** ImageIO validator returns bounded actual raster dimensions/data; normal asset factory reuses writer vault key and directory-bound lease, private factory shares private-group memory only. Captures consume existing source identity/output/fullscreen contexts and return a validated still-image draft with attribution and captured destination profile.

- [ ] Write real malformed/oversized image tests and captured-source tests for primary/split/Peek/Quick/Reader/fullscreen, cancellation after navigation/transfer/retirement/clear/delete/shutdown, asset-before-metadata rollback and profile erasure without deleting another canvas's references. Expected: behavior failures before implementation.
- [ ] Implement import, preview/crop/destination, capture menu/command, asset publication and resumable profile cleanup; preserve canvases on website-data clear. Expected: valid images render, canceled work publishes nothing, no stale profile resurrection or private disk/key access.
- [ ] Run default and VM image/capture/lifecycle checks; perform real page/fullscreen/Reader capture acceptance. Commit and task-done.

### Task 5: Portable export and final qualification

**Files:** create core offline HTML/PNG render/export helpers and checks; connect existing output/save-panel coordination; update documentation.

- [ ] Write adversarial Unicode/text/URL/image export tests, missing-asset handling, normal/private destination cancellation, and stale output context tests. Expected: failures before implementation.
- [ ] Implement PNG and self-contained inert HTML exports; preserve original canvas on cancellation/failure. Expected: offline roundtrip has all content, no scripts/network execution and correct attribution.
- [ ] Run the full suite, universal package/signature/resource verification and live VM native input/AX/appearance checks. Expected: all required checks pass; report any unsupported context honestly.
- [ ] Commit, task-done, obtain the required final fresh whole-branch review and fix consequential findings once with RED→GREEN evidence. Integrate/release only after all earlier parity and release gates are met; keep the overall browser goal active for unfinished features.
