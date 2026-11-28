# Native Easel drawing verification

Drawing development is on `feature/easel-drawing`. The public 0.21 preview does not include it. The full browser objective and the older editor, extension-engine, accessibility and installed-app acceptance gates remain open.

The candidate application source is `33543ac66237624dc485011e41394691be37f661`. Later test-only commits keep its application source unchanged. The complete candidate suite, both optimized architectures and universal packaging are being checked in [run46091122141](https://github.com/SinfulSoul007/alcove/actions/runs/46091122141). A new drawing DMG has not yet passed independent download and mounted-image verification.

Select, Pen, Line, Arrow, Rectangle and Ellipse are available above the canvas. Color, thickness and opacity affect subsequent marks. The compact menu retains all tools and styles in narrow panes. V/P/L/A/R/E shortcuts work while the canvas owns focus; note input and marked text keep their own responder. Escape cancels an unfinished mark. Selection, move, resize, delete, layering and native undo/redo apply to saved drawings.

Completed drawings that fail to save use the existing writer-owned draft coordinator. They survive view destruction, block destructive close/quit paths, and offer explicit retry, recovery as a new item, or discard. Profile retirement and ownership checks also cover pending drawings. A transient preview is excluded from persistence and export.

| Scope | Observed evidence | Limits |
| --- | --- | --- |
| Geometry, sampling and documents |232 pure core/asset/model/document/gesture assertions; includes100,000-event bounded sampling and protected format10 documents | Output counts, not a browser security or speed certification |
| Document/render/export integration | Source0ef3857 passes270 assertions across12 native/model/store/editor/export/ownership groups | Predates the drawing interaction and toolbar implementation |
| Interaction and controls | [Run46089767685](https://github.com/SinfulSoul007/alcove/actions/runs/46089767685) passes35 interaction and19 actual native control checks, zero cycles; all182 application input hashes match sourcefa1dfd4 | Includes actual sibling window owners, failed-save retention, retry, IME guards and50-point toolbar bounds; full candidate regressions remain pending |
| Current native browser UI | [Run46091124983](https://github.com/SinfulSoul007/alcove/actions/runs/46091124983) passes15 checks, zero cycles; eight compositor captures and all182 source hashes authenticated for33543ac | Owned hosted macOS26.5 windows; no ordinary installed-app, VoiceOver, hardware or frame-time claim |
| Normal UI recovery and cold reopen | [Run46096385938](https://github.com/SinfulSoul007/alcove/actions/runs/46096385938) dispatched against unchanged33543ac application source | Pending; uses an injected test key and cannot establish real Keychain authorization behavior |

The compositor witness posts actual application mouse events, previews a pen stroke above an image, saves it, performs native undo/redo, preserves the note editor, resizes the sidebar/window, draws white ink on dark paper and opens compact split panes. A real one-pixel stale edge after zoom was reproduced from authenticated output; document invalidation repaired it. The final native probe reports zero channel difference across the previously stale boundary before the separate repaint control.

Drawings use validated typed paths and protected format10 metadata. Logical boxes are40...4096 points, strokes contain at most4096 samples, and a board retains at most65536 drawing samples alongside its500-item limit. HTML emits generated SVG; PNG uses the same path commands. The existing128MiB HTML and16MP/8192-pixel PNG export limits remain. Export snapshots the visible paper color so light ink stays visible on dark paper.

The final source suite, independent universal ZIP/DMG verification and one fresh whole-feature review remain required before integration. This work adds no general Chrome API or original full uBlock capability. Those remain separate engine, packaging, signing and native-qualification requirements.
