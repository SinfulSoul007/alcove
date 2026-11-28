# Interactive Easel Live Captures Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Play and use a real profile-owned webpage inside an Easel capture while preserving protected offline previews and browser page lifetimes.

**Architecture:** Validated persistent viewport/crop/source values accompany an encrypted fallback asset. Runtime child page records use the existing registered web-view factory/delegates and profile ownership; a native clipped host handles actual input at canvas magnification. Capture publication and preview replacement use revision-checked asset/document transactions.

**Tech Stack:** Swift/Foundation, AppKit/SwiftUI/WebKit, existing protected metadata/assets; macOS14+/universal unchanged, existing extension availability15.4+ unchanged.

**Spec:** `docs/superpowers/specs/2026-11-28-easel-live-captures-design.md`

## Global Constraints

- Native captured viewport width/height1...8192 points; CSS document scroll x/y0...16,777,216; pageZoom0.5...3; all finite. Normalized crop x/y0...1, width/height>0 and right/bottom<=1. Complete definitions require at least1 native cropped point per side.
- Preview dimensions1...16384, at most40,000,000 pixels; source HTTP(S) URL<=8192 UTF-8/no credentials/controls/invalid port; title nonempty<=256 UTF-8. Reuse existing image/link validation.
- Metadata format11 at content integration; preserve format10 readers/migration and refuse editing unsupported newer documents. Keep500 items/16384 canvas,128MiB HTML and16MP/8192px PNG bounds.
- Opening a saved board never starts live network pages. Play is explicit; normal definitions/assets stay encrypted, private stays memory-only/no normal key. Capture deadline20seconds.
- GUI execution only dedicated VM or hosted macOS. The shipping0.22.1 sourcefb3b90b and its exact package/release gates remain independent and frozen.

## Review Focus

- A slow page load, later navigation or a changed crop must not publish mismatched pixels/configuration or revive a stopped child after profile retirement.
- Actual text input and mouse positions must survive fractional canvas zoom, host resizing and a live Easel tab handoff without entering another card/window.
- A webpage navigating to a different origin must retain real browser policy checks and attribution; a capture must not borrow another tab's extension/permission identity.
- Shared-board edits, failed saves and Undo must preserve the correct preview asset and still-owned live view; a failed item removal cannot close the saved page.
- Background media, website fullscreen or pending permission/download decisions must complete or retire against the same owner; no orphan page or stale native host survives.

---

### Task 1: Validated persistent source, viewport and crop values

**Files:** Create `Sources/BrowserCore/EaselLiveCapture.swift`, `scripts/EaselLiveCaptureCoreChecks.swift`; minimally adjust `Easel.swift` validation visibility and focused build flags in `scripts/build.sh`.

**Interfaces:** Public immutable Codable/Equatable/Sendable `EaselCaptureViewport(width:height:scrollX:scrollY:pageZoom:)`, `EaselCaptureCrop(x:y:width:height:)`, `EaselLiveCapture(previewAssetID:pixelWidth:pixelHeight:sourceURL:sourceTitle:viewport:crop:)`. Fields use the spec's exact names/units/bounds. Reuse current image-content validation internally, without widening public validation API or adding the new content case yet.

- [x] Write independent pure checks for roundtrip, all endpoints/nonfinite/negative/out-of-bounds geometry, overflowing normalized sums, image area bounds, source credentials/control/port/title limits and corrupt decoded fields. Run before implementation; expect missing types.
- [x] Implement validating initializers and decoding. Run focused checks plus the existing complete core/asset/drawing/document tests; expect no failures without opening an app. Add `ALCOVE_EASEL_LIVE_CORE_ONLY=1` to select that command and integrate these checks into the default suite.
- [x] Strict whole-app typecheck using the pinned compatible SDK; commit and task-done with `env ALCOVE_EASEL_LIVE_CORE_ONLY=1 ./scripts/build.sh`.

### Task 2: Content, atomic capture, fallback rendering and inert export

**Files:** Extend `Sources/BrowserCore/Easel.swift`, `Library.swift`, `EaselExport.swift`; `Sources/Browser/EaselCapture.swift`, `EaselCaptureCoordinator.swift`, `EaselCaptureNative.swift`, `EaselCardView.swift`, `EaselImageAssets.swift`, `EaselCanvasView.swift`, `EaselExportRenderer.swift`; create `scripts/EaselLiveCaptureDocumentChecks.swift`, `scripts/EaselLiveCaptureStoreChecks.swift`, `scripts/EaselLiveCaptureNativeChecks.swift` and `scripts/build.sh easel-live-capture-test`.

**Interfaces:** `EaselItemContent.liveCapture(EaselLiveCapture)`, format11. `EaselCaptureGeometry(viewport:crop:)` is a captured immutable value, separate from runtime views. Add `EaselItemContent.previewAssetID: UUID?` for common reference accounting and a derived `imagePreview` tuple (assetID, pixelWidth, pixelHeight, optional sourceURL/sourceTitle) for the same fallback renderer. Neither derived property is encoded. Extend publication with an optional immutable live definition; static callers retain current behavior. Destination/revision/profile checks and asset rollback remain common.

- [ ] Write RED cases for format10 migration/newer refusal, encrypted/private roundtrip, image-reference/undo/prune accounting, geometry changing during snapshot, Reader static-only availability, stale destination/source cancellation, save failure rollback and inert offline outputs. Preserve all earlier image/capture/drawing/export assertions.
- [ ] Integrate the content model and shared preview rendering/export. Capture native WK bounds/pageZoom plus CSS scroll at both ends of the real snapshot; reject moved geometry. Save crop/config/preview atomically. Expose no nonfunctional Play action before Task3.
- [ ] Run actual page and ready-Reader capture, private/no-key, native fallback pixels, export and existing ownership/history regressions in VM/CI. Strict compile, commit and task-done with `./scripts/build.sh easel-live-capture-test`.

### Task 3: Registered live pages, browser policy and native interaction

**Files:** Create `Sources/Browser/EaselLivePages.swift`, `EaselLiveCard.swift`, `EaselLiveCaptureActions.swift`; extend `BrowserStore.swift`, `BrowserActions.swift`, `BrowserProfiles.swift`, `QuickBrowseActions.swift`, `BrowserAppDelegate.swift`, `ExtensionTabs.swift`, `ExtensionWindows.swift`, relevant extension binding enumeration, `EaselCardView.swift`, `EaselCanvasView.swift` and capture preview. Add `scripts/EaselLivePageChecks.swift`, `scripts/EaselLiveInputChecks.swift`, `scripts/EaselLivePolicyChecks.swift` and `scripts/build.sh easel-live-page-test`.

**Interfaces:** `EaselLivePageKey(tabID:itemID:)`; a MainActor `EaselLivePageRecord` holds fresh page UUID, owning tab/item/profile/store lease/generation and runtime BrowserCore.Tab state. BrowserStore operations `playEaselCapture(_ key: EaselLivePageKey) throws -> WKWebView`, `stopEaselCapture(_ key: EaselLivePageKey) async -> Bool`, `liveCapturePage(_ id: UUID) -> EaselLivePageRecord?`, `liveCaptureID(for web: WKWebView) -> UUID?`, `isCurrentLiveCapture(_ web: WKWebView, focused: Bool) -> Bool` and idempotent `retireEaselLivePages(profileID: UUID? = nil, tabID: UUID? = nil, itemID: UUID? = nil) async throws`. Shared view registration, `tab(id)`, profile/space lookup and observation update recognize this explicit runtime page role. No fake Quick Browse or persistent sidebar records.

- [ ] Write RED lifecycle checks: two captures/boards/profiles, private no-key pages, source retirement during load, Stop twice/late callbacks, failed removal retains live view, successful remove/Undo retains fallback, process failure/retry and no automatic restart on cold restore. Verify web factory configuration, real protection/permission callbacks, runtime extension query/reload/navigation/close identity and explicit unsupported child operations. Include current capture pages in media/suspension/erasure/shutdown and shared normal-window handoff.
- [ ] Implement real profile-bound registered views and explicit runtime tab adapters. The current live origin and saved source URL remain separate; ordinary URL observations never rewrite persistent capture definition. Reuse common navigation, permission, popup/download and fullscreen paths with generation guards. Normal CmdW still addresses the owning Easel tab.
- [ ] Implement native clipped presentation and compact accessible controls. Play restores native viewport/pageZoom and CSS scroll; canvas/resize changes preserve native web identity and transform input correctly. Stop closes the runtime page through common cleanup and retains fallback. Update Preview and explicit Replace Source use one undoable asset/document transaction. Drawing/select tools keep proper native hit testing.
- [ ] Run genuine external/native mouse and Unicode text input against an owned HTML button/form at canvas zoom0.25,0.5,1,2 and mismatched card aspect ratios. Test multiple independent cards, drawing above a card, narrow/split controls, focus, normal/private website state, handoff preserving a form, and fullscreen exit/retirement. Direct JS calls may observe state but cannot substitute for physical interaction.
- [ ] Run focused live-page/input/policy/history regressions plus relevant current browser/window/extension/capture checks; authenticate owned captures; strict compile, commit and task-done with `./scripts/build.sh easel-live-page-test`. Keep explicit remaining engine, minimum-OS/hardware/VO/performance gaps.

### Task 4: Combined qualification and next preview

**Files:** Required-check integration, acceptance/release verification docs; product fixes only from the single whole-feature review or actual observed failures.

- [ ] Run complete exact-source suite, both optimized architectures, universal ZIP/DMG and independent downloaded read-only mount/eject checks. Run ordinary installed normal/private Play/input/Stop/reopen/export on the exact final artifact.
- [ ] Obtain one fresh whole-feature review of the entire change from the Task1 base. Re-grade; fix consequential findings once with observed RED-to-GREEN and final green regression/package evidence. Record deferred minors and declined gates; no repeated reviewer loop.
- [ ] Commit/push qualified source, prepare a version/tag matching the next preview, publish only applicable qualified artifacts and verify public downloads/signed updater transition. Preserve broader Arc/Chrome/original-uBlock/signing/hardware acceptance as active. Live Captures alone do not complete that goal.

## Pre-flight

Task1 value units are native WK bounds plus CSS scroll, not interchangeable CSS/native viewport widths. Task2 consumes exactly those immutable values and freezes them with pixels before asset publication. Task3 consumes Task2 preview identity and never persists live form/navigation state implicitly. Task4 qualifies final actual source and package, independent of the already-running0.22.1 candidate. Builder check on the written design returned "nothing important left"; routine choices remain delegated by the user.
