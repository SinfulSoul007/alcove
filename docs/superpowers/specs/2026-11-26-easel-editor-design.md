# Native Easel editor and capture design

This implements the canvas experience on top of the reviewed Easel storage foundation. It advances the existing Arc-parity goal; it is not a replacement definition of browser completion. macOS 14 remains the minimum. No new package dependency, key provider, Keychain policy or WebKit privilege is introduced.

## Approach

Use native AppKit views inside the existing SwiftUI browser pane. A web editor would need a privileged bridge to local notes and encrypted images; native editing fits the application's existing storage and focus model. Use an `NSScrollView` for magnification/panning, individually accessible cards for notes, links and images, and real `NSTextView` text editing. These are implementation decisions under the user's instruction to proceed; no design approval loop is required.

## Canvas tabs and transactions

- Reserve the application-owned `alcove` URL scheme for native content. Easels use the exact route `alcove://easel/<UUID>`. The parser accepts ASCII case differences, but rejects credentials, ports, escaped paths, queries, fragments, extra segments and malformed identifiers. Ordinary URL resolution and external/extension web navigation do not gain access to native routes.
- The route contains an identifier, not authorization. Resolve it only in the live tab's actual profile library and actual window presentation. Unavailable profiles and missing canvases render an unavailable native pane. Never send an application-owned route to WebKit, attach an extension runtime to it, or register a WebKit view for it.
- New Easels create a durable board plus a pinned tab in one existing document transaction. Opening an existing board reuses its tab in the chosen Space, or creates a pinned tab there. The target Space/profile is captured when the action begins; later selection changes cannot redirect it. The same UUID in another profile does not authorize access.
- Edits require the captured revision, profile, tab and window presentation. Apply a batch to a candidate copy, persist it once and then publish; an invalid later edit or a failed save publishes nothing. Renaming a canvas updates its native tab titles in that profile while preserving user-supplied custom tab titles.
- Closing or archiving a canvas tab keeps the canvas in Library. Deleting the canvas itself is a separate explicit operation. Folder/pin/Space movement retains its native route; cross-profile moves must not expose another profile's canvas. Missing routes are recoverable without crashing or opening a web page.

## Editing and focus

- Notes, link cards and still images use the validated storage frames and content. The 16384-point canvas and current limits remain authoritative. Drag and resize update the local view during the gesture and commit once at its end. Clamp at canvas boundaries; don't persist every mouse event.
- Text drafts debounce for 250 ms. A draft captures the board revision and remains owned by the store while dirty, even if its view is unmounted. Native typing, selection, clipboard, input methods and undo work normally. Reject an oversized text replacement before it enters the editor; never truncate an existing note silently.
- Flush a draft before another operation on the same board, tab/window closure or application termination. On a failed or stale save, keep the complete draft, show an actionable save/conflict state and cancel destructive closure until the user retries or explicitly discards it. Selection changes must not silently discard an unsaved draft. A subsequent profile clear/deletion cannot republish a stale draft into a retired profile.
- A stale draft may rebase only when the latest item's content still equals the captured original content; preserve its latest frame/layer and commit against the latest revision. If that note's text changed or the note was removed, preserve the draft and offer Copy Draft, Save as New Note, or Discard Draft. Saving as a new note keeps the other editor's text. A missing board requires an explicitly chosen new canvas in the same still-live profile; never automatically restore a deleted profile. Explicit confirmed profile deletion invalidates its drafts.
- Canvas undo/redo uses successful committed changes and the resulting revision. A stale undo must preserve newer work. Native text editing keeps its own undo behavior. Board delete and arrow keys act only when the canvas is first responder, not while text editing or a command field is active.
- Add-note/add-link/import-image, select/move/resize/delete, layer ordering, zoom in/out/reset and fit-content have labeled keyboard-accessible controls. Magnification range is 0.25...2.0. Selected-card chrome and a quiet dotted background follow the active theme; Reduce Motion disables decorative transitions. Preserve scroll/zoom and active editing state across ordinary browser redraws.

## Images, assets and profile lifecycle

- Obtain normal asset stores from the existing unlocked metadata writer key, root and matching ownership lease; do not call a key provider again. Private assets belong to the private browsing group only and never fall through to a normal asset store.
- Local image import uses the native open panel. Bound bytes before reading, validate with ImageIO before allocating a full raster, check actual dimensions against the model limits, and reject unsupported/non-raster content. Use the same validation when rendering stored bytes. User filenames never become asset paths.
- Stage the encrypted asset before committing its metadata reference. If publication fails or the captured profile/window is no longer valid, remove only the newly created unreferenced asset. Crash leftovers remain encrypted and can be cleaned only after proving ownership and lack of references.
- Website-data clearing cancels pending captures/imports and preserves saved canvases and their assets. Profile deletion uses the existing resumable deletion/tombstone flow to retire its canvases and owned asset namespace. Do not delete shared image references while another canvas in that profile still uses them.

## Page capture and export

- Capture the visible primary, split, Peek or Quick Browse document using public APIs and the existing source-bound output/fullscreen lifecycle. Capture callbacks retain the exact profile/document/presentation/window identity. Navigation, transfer, retirement, clear, deletion and shutdown cancel stale publication.
- A Reader page is captured as the displayed Reader content, not its hidden original. A native canvas uses its own renderer/export path. Fullscreen exit and native chooser presentation follow the existing barrier; never reparent a borrowed WebKit view or weaken user activation/media policy.
- Show a preview with crop and an explicit destination canvas. New-canvas capture and add-to-existing-canvas both work; source URL/title are retained with the still image. Live Captures are a separate unfinished requirement, not a label for screenshots.
- Export PNG and a self-contained offline HTML document through the existing save-panel/output coordinator. Escape all text, allow only the validated HTTP(S) source links and embed raster data without scripts or automatic network requests. Private export is an explicit user action, never an automatic disk write.
- PNG exports include the union of all content plus a 48-point margin; an empty canvas uses 960×640 points. Default scale is 2×, reduced uniformly to at most 8192 pixels per side and 16 million pixels total, with dimensions shown before saving. Preserve all content without cropping. Decode/render images sequentially at the required output size and bound the decoded-image cache to 96 MiB; never allocate the full 16384×16384 canvas raster or retain all full-resolution source rasters.

## Integration and acceptance

Expose New Easel and Capture Page in File, command search and the sidebar creation menu. Library gets an Easels collection with open, rename and explicit permanent-delete actions. Keep unavailable-profile states, normal/private badges and existing browser command routing correct. Use owned test data only; leave extra QA windows closed afterward.

Acceptance includes real normal/private store transactions, encrypted relaunch, stale revision and save-failure rollback, no native WebKit/extension registration, window/Space/profile lifecycle, draft retention on save/close failure, actual image validation, stale capture cancellation, offline escaped export, and live VM keyboard/drag/resize/zoom/appearance checks. The existing full suite and universal package checks must pass before integration or release. Cloud sharing/collaboration, drawing tools and Live Captures remain in the broader goal until implemented; this local editor does not imply those are complete.
