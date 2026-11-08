# Native page output

The full browser goal needs printing and page saving in addition to sidebar fidelity. Add native user-invoked output for the visible page: File → Print… (Command-P), Export as PDF… and Save Page As… (Command-Shift-S, WebArchive). Command-S continues to toggle the sidebar. Split-pane focus, primary/Quick Peek, Quick Browse and private pages must select their actual visible document.

## Approach and constraints

Use system WebKit PDF/WebArchive capture and its NSPrintOperation, native per-window sheets, and atomic writes to an explicitly selected file. A custom HTML renderer would lose website layout; an app-modal print loop would block unrelated windows. This is the implementer's choice under the user's standing instruction to proceed without design questions, not a new user-selected format preference.

Keep macOS14 minimum, metadata format3, profile ownership, themes, current sidebar shortcuts and unsigned-preview labeling. No dependencies, private APIs, automatic printing/export, arbitrary filesystem access or global input synthesis. Add only the documented `com.apple.security.print` entitlement; existing selected-file read/write supports exports. Saved/printed content is explicitly outside metadata encryption, including from private windows.

## Ownership and lifetime

A coordinator owns one output job per native window. Each job captures weak store/view/window references, profile ID, original URL and a unique token. Begin only for the actual focused visible page in an owned browser window, with an available profile, no existing native sheet and no active output job. A menu fallback to a normal store without a browser window must not export anything.

Generate PDF/WebArchive asynchronously, bounded by a30-second preparation deadline. Before presenting a save sheet and accepting its result, recheck the same live mounted view, profile, URL and visible-page ownership. Accepting a legitimate sheet result must not depend on the moment AppKit restores key status. Duplicate/stale callbacks cannot write twice or finish a replacement job. Cancel, invalidated ownership, close or generation failure before confirmation writes nothing. Window close clears pending jobs and dismisses their owned presentation. Native printing always retains its standard final Print confirmation; already accepted/spooled printing is not retractable by closing a page.

After a valid destination is accepted, dispatch atomic file writing away from the main actor. This is the commit boundary: a subsequent window close need not undo an explicitly accepted export. Suppress stale completion messages; never update another profile/window's UI. Errors stay local. Filename defaults use a sanitized, byte-bounded title or Page, never credentials/query strings from the URL. Native file types and extensions match the chosen format.

## Verification and remaining scope

Owned never-shown fixtures can exercise the real coordinator, target routing, cancellation, repeated callbacks and real temporary file writes while replacing only native presentation/external completion boundaries. Real nonpersistent WebKit documents must produce PDFs with expected document text and WebArchives with expected main-resource content. Native print-operation construction and actual menu registrations must be checked without printing or opening user panels.

Live print/save-sheet UX, a physical printer, sandboxed print-device execution, minimum-OS/Intel execution and quarantined installation remain explicit gates. Opening saved archives in Alcove and website-initiated `window.print()` remain browser-essential work; the public WKUIDelegate header has no printing callback, so do not introduce a private delegate method or claim those workflows here. Full Arc parity, security certification and performance remain unfinished.
