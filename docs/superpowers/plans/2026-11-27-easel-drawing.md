# Editable Easel drawing implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add editable native pen/shape drawings to protected Easels, including undo and faithful exports.

**Architecture:** Typed bounded vector geometry feeds native path rendering and generated SVG. Existing profile transactions, item frames, revision ownership and canvas history handle persistence and edit safety. A native preview captures gestures above existing cards and commits one revision-checked transaction.

**Tech Stack:** Swift/Foundation, AppKit/SwiftUI, Core Graphics, existing AES-GCM metadata storage; macOS14+/universal unchanged.

**Spec:** `docs/superpowers/specs/2026-11-27-easel-drawing-design.md`

## Global constraints

- Pen/Line/Arrow/Rectangle/Ellipse/Select; canonical#RRGGBB, thickness1...32, opacity0.1...1; logical box40...4096, finite points0...4096,1...4096 pen points/exactly2 shape endpoints. Board point budget65536; existing500 items/16384 canvas/item frames retained.
- Preserve normal encrypted/private memory-only ownership, revision/undo/draft/retirement semantics. No new Keychain/network/permissions/dependencies.
- Metadata format10 at content integration; older documents stay readable, unsupported newer documents refuse writes.
- Keep export128MiB HTML and16MP/8192px PNG bounds, CSP and explicit destinations. Drawings export as generated vectors/paths; no external SVG parsing.
- Host runs only non-GUI tests/typechecking. Native GUI execution/captures in dedicated VM/hosted macOS; existing grant only. Full browser/engine/signing gates remain separate.

## Review focus

- Toolbar actions or switching tools during IME/text editing must not lose a note draft or hijack its shortcuts.
- A board changed in a sibling window during a gesture must preserve both the newer board and the pending mark without stale publication.
- A long/high-frequency pen drag must remain bounded without freezing, truncating silently or replacing its endpoint.
- Thin, single-point, reversed, near-edge and resized drawings must render/export consistently and remain selectable.
- In-flight preview/undo from a cleared/retired/transferred profile must not resurrect its data or leak into another profile/export.

---

### Task 1: Validated logical drawings and deterministic paths

**Files:** Create `Sources/BrowserCore/EaselDrawing.swift`, `scripts/EaselDrawingCoreChecks.swift`; extend focused core commands in `scripts/build.sh`.

**Interfaces:** Public immutable Codable/Equatable/Sendable `EaselDrawingPoint(x:y:)`, `EaselDrawingStyle(color:lineWidth:opacity:)`, `EaselDrawingKind`, `EaselDrawing(kind:viewBoxWidth:viewBoxHeight:points:style:)`. Derived `EaselDrawingPath(commands:filled:)` and `EaselDrawingCommand` move/line/quadratic/cubic/close cases; no geometry cache in encoded data.

- [x] Write independent fixtures for JSON roundtrip/canonical color, all input bounds, incremental oversized decode, wrong endpoint counts/zero-area shapes, hand-derived rectangle/ellipse/arrow geometry, pen smoothing and visible coincident-point dots. Run before implementation; expect missing APIs.
- [x] Implement types and deterministic local paths with stroke-safe bounds. Run pure drawing checks plus the existing complete core/asset command; expect all green without launching an app.
- [x] Integrate `ALCOVE_EASEL_DRAWING_CORE_ONLY=1 scripts/build.sh` and the default core check. Strict compile the actual application sources with the new model. Commit and task-done using the focused+core command.

### Task 2: Document integration, rendering and export

**Files:** Modify `Easel.swift`, `Library.swift`, `EaselCardView.swift`, `EaselExport.swift`, `EaselExportRenderer.swift`; create native drawing renderer and focused core/store/pixel/export checks.

**Interfaces:** Add `EaselItemContent.drawing(EaselDrawing)`, enforce aggregate point budget atomically, metadata format10. Native renderer consumes Task1 path commands and logical-to-item transform. Drawing card is transparent, supports existing selection/resize/layer/history and path hit testing. HTML emits generated SVG from the same path commands.

- [ ] Write RED checks for drawing document roundtrip/encrypted and private persistence, point-budget rollback, format9 migration/newer-reader refusal, transparent real rendered pixels, thin/dot/reversed/resized paths, stacked hit testing and inert offline HTML/PNG including opacity/layer order.
- [ ] Implement integration and renderer/export without exposing tools yet. Compile every exhaustive content switch. Run new checks and existing model/assets/editor/export/ownership regressions on current sources; native work only VM/CI. Commit and task-done.

### Task 3: Gesture preview and responsive drawing controls

**Files:** Extend `EaselCanvasView.swift`, `EaselCanvasActions.swift`, `EaselPane.swift`; create `EaselDrawingInteraction.swift` and native gesture/tool checks.

**Interfaces:** Published canvas tool/style, begin/preview/commit/cancel drawing methods scoped to captured `EaselTabContext`. Bounded samples retain first/current points, native overlay intercepts only drawing gestures; commit calls existing history transaction once. Tool actions finalize notes through current board preflight.

- [ ] Write RED real-input checks: dots/drags at magnification, continuous previews without persistence/editor remount, single-step undo/redo, cancel/Escape, missing/stale/replaced board/profile, failed save, sibling conflict, long gesture/sample compaction, note/IME shortcut guards, toolbar widths and accessible labels.
- [ ] Implement tools, palette/thickness/opacity, native preview/path interaction and compact controls. Preserve pending mark/error for retry where safe; explicit cancellation after scope retirement. Run all new and relevant current native/window/export regressions; observe actual typed/dragged UI and owned captures. Commit and task-done.

### Task 4: Whole-feature qualification

**Files:** Update acceptance/release verification docs and required checks; actual fixes follow one final whole-feature review.

- [ ] Run complete suite, both optimized architectures and universal package verification against the exact feature source. Download/authenticate/mount the produced package. Observe normal/private save/reopen, undo, drawing over images, toolbar resizing and PNG/HTML outputs with native UI.
- [ ] Obtain one fresh whole-feature review from1136915 through final implementation. Re-grade, fix consequential findings once with RED→GREEN cases and green suite; retain manual AX/hardware/installed/public gates honestly.
- [ ] Commit/push verified work; keep broader full-browser and older editor acceptance requirements active. Publish only after applicable release gates; do not claim the entire browser finished.

## Pre-flight

Task2 consumes Task1 immutable validated paths; no web parser or duplicated path algorithm. Task3 consumes Task2 content/rendering and existing revision history; a preview must not enter persistence/export before commit. Task4 covers the combined drawing/editor/export behavior. Native/Apple signing prerequisites remain external and do not waive the drawing gates.
