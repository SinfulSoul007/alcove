# Editable Easel drawing

## Intent and authority

The active user goal includes Arc's full feature set, visual polish, customization and browser extensions. Existing Easels support notes, links, images and captures but lack drawing. This work adds independently implemented pen and shape tools; the rest of the browser goal remains active. The user repeatedly requested continuous implementation and delegated engineering choices. The choices below are the implementer's calls, without another design-approval pause.

## Approach

Use validated vector drawings as canvas items, retaining the existing encrypted profile catalog, revision-checked edits, native canvas, undo and explicit exports. Rasterizing marks into image assets would make resizing and individual edits lossy. Embedding a separate web drawing application would duplicate profile, draft, focus and export ownership. Native vectors fit the current editor; no additional dependency or service is needed.

## Required behavior

- Tools: Select, Pen, Line, Arrow, Rectangle and Ellipse. A drag previews locally, then commits once on release and creates one undo action. Clicking with Pen creates a visible dot. Existing notes, images and links remain editable; a drawing tool can mark over them. Selection, move, resize, delete, layering and undo apply to drawings. Escape cancels an in-progress mark; focus, profile, board or revision changes cannot publish stale marks.
- Draw settings include color, thickness and opacity for subsequent marks. Use the Space accent initially. Keep the full toolbar and compact menu usable; keyboard shortcuts act only while the canvas owns focus and never intercept note input or marked text. Label tools and controls for accessibility.
- Store each drawing as a typed immutable value: kind, logical view-box size, logical sample points and style. The item frame maps the logical drawing into its current canvas rectangle. Resizing scales the entire drawing, including its line width. Samples and generated path must stay within their logical view box, accounting for stroke thickness.
- Kinds are `pen`, `line`, `arrow`, `rectangle`, `ellipse`. Logical width/height are finite40...4096; points are finite0...4096. Pen accepts1...4096 samples. Other tools require exactly two distinct endpoints; rectangle/ellipse require nonzero width and height. Color is canonical#RRGGBB; thickness1...32 logical points; opacity0.1...1. Path generation is deterministic and shared by native rendering and SVG export through typed move/line/quadratic/cubic/close commands. Repeated pen samples form a visible dot when all coincide. Arrowhead length is min(max(12,3×thickness),40% of shaft length), with half-length side offsets.
- Reject invalid/oversized values during construction and decoding, before publishing changes. Decode pen points incrementally and reject more than4096 samples. A board may contain at most65536 drawing sample points in addition to its existing500-item limit; edits remain atomic. The native sampling buffer stays bounded and may compact intermediate samples while retaining the first/current endpoint. Tell the user about an uncommittable gesture without changing earlier items.
- A new drawing content case requires metadata format10, so older readers refuse unsupported data rather than overwrite it. Existing format9 documents and all earlier content remain readable. Private drawings stay in the existing memory-only profile. No new Keychain lookup, plaintext staging or permission is introduced.
- Drawing views have transparent backgrounds and no note-card fill/header. Selection handles and accessible labels remain available. Hit testing in Select mode follows the actual path with a usable tolerance, allowing clicks through empty portions to lower layers. Drawing mode intercepts canvas drags above existing cards. Use an isolated preview layer; do not rebuild note editors while sampling.
- Native PNG and portable HTML preserve order, geometry, color, opacity and all drawings. HTML embeds only generated SVG numeric commands and validated color; existing restrictive CSP, escaped text,128MiB output and PNG16MP/8192px limits remain. No scripts, network assets or SVG supplied by websites/users are interpreted.
- Normal/private relaunch, failed-save rollback, sibling/editor conflict, export cancellation, erasure and retired-profile behavior retain existing ownership rules. No ordinary installed-app, accessibility, animation-performance or whole-browser completion claim comes from narrow model checks.

## Boundaries and verification

The existing finite16384 canvas and40...4096 item frames remain engineering limits for this iteration; wider/infinite-canvas parity remains part of the full goal. Live Captures, sharing and sync remain separate gaps. No release tag, updater platform claim or engine capability changes in this work.

Use pure model/geometry/JSON tests first, then actual store/editor/path/pixel/export tests. Native execution happens only in the dedicated VM or hosted macOS; host compilation and non-GUI core checks are allowed. Obtain genuine native-window captures and actual input/undo/resize tests before calling the drawing UI complete. Keep one fresh whole-feature code review after implementation and fix consequential findings with RED→GREEN evidence.
