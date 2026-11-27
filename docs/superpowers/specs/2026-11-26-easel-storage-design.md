# Easel storage design

Alcove needs native canvas tabs for collecting notes, links and captures. This is part of the existing Arc-feature goal. This first, independently testable subsystem supplies durable canvas documents and protected capture storage. The editor, capture UI and public release follow on the same feature branch; storage alone is not a completed Easel feature.

## Decisions and alternatives

These are implementation decisions made under the user's instruction to proceed autonomously. An HTML canvas could reuse WebKit, but gives privileged local content an unnecessary web bridge. A native canvas can use AppKit editing, accessibility and scrolling without that bridge, and is the chosen editor direction. Embedding screenshots in the metadata JSON would make every edit rewrite all image bytes; instead, the protected document contains asset UUIDs and the image bytes live in a separate encrypted store.

Cloud collaboration, public sharing and interactive Live Captures remain requirements to investigate and implement separately; a local still capture must not be described as those features. Arc references: [2021 introduction](https://resources.arc.net/hc/en-us/articles/20498463803799-Arc-for-macOS-2021-Release-Notes), [Live Captures](https://resources.arc.net/hc/en-us/articles/20498417809815-Arc-for-macOS-2022-Release-Notes), [export](https://resources.arc.net/hc/en-us/articles/25583851606039-How-Do-I-Export-My-Data-from-Arc).

## Document contract

- macOS 14 minimum; Foundation/CryptoKit/Darwin only in BrowserCore. No new dependency, key provider or Keychain behavior.
- `BrowserLibrary.easels: [Easel]?` is profile scoped. Absence decodes old libraries. `BrowserDocument.currentFormatVersion` becomes 9 so an older binary cannot silently overwrite new saved content.
- `Easel` has stable UUID identity, nonempty title, created/modified dates, a UUID revision and ordered items (back to front). Items have stable UUID identity, frame and note/link/image content.
- Canvas size is 16384 × 16384 points. Frames must be finite, remain inside the canvas, and have width/height between 40 and 4096 points. Reject malformed frames on construction and decoding.
- Titles have at most 256 UTF-8 bytes; notes at most 16384 UTF-8 bytes; a board has at most 500 items. Image dimensions are positive, at most 16384 each, and at most 40 million pixels. Image source links and link cards accept absolute HTTP(S) URLs with a host, without credentials. Link titles are bounded like board titles; source titles may be absent. Never fetch a link to validate it.
- Edit operations are insert, replace, remove, reorder and rename. They require the caller's expected revision. Validate a candidate copy before publication; stale or invalid edits leave the old document byte-for-byte equivalent. Effective edits advance revision and modification date; no-ops do neither. Reorder requires an exact permutation; removal of unknown IDs is rejected.
- Decode invalid or ambiguous duplicate item identities as an error, without dropping saved material. Same-ID, unequal boards in a library merge are retained with a new board UUID and an optional `recoveredFromID` recording the colliding source. Equal records with the same identity are deduplicated; distinct board identities always survive even when their content matches. Recovery lineage avoids another copy when the same conflict is imported after relaunch. Item identities are local to their board.

## Asset contract

- `EaselAssetStore` has explicit normal and private initializers. Normal mode consumes an already unlocked metadata key and optional ownership lease; private mode takes no key and never reads or creates filesystem entries.
- Normal storage takes an existing, owned metadata directory; it creates only `Easels/<profile UUID>/`. UUID asset filenames are immutable ciphertext. All directories are 0700 and files 0600.
- Use AES-GCM with authenticated data binding format version, profile UUID and asset UUID. Copying a valid ciphertext under another profile or asset UUID must fail authentication. No plaintext staging file is ever written.
- Reject empty or larger-than-32-MiB inputs and larger ciphertext before allocation. This store handles bytes; the capture/import layer will validate actual image decoding and dimensions before storing and before rendering.
- Use no-follow directory/file descriptors; reject symlinks, nonregular files, hardlinks, foreign owners, and replaced directories. Bind a supplied metadata lease to the root's opened device/inode before creating directories and validate that binding on every operation. Stage encrypted bytes under a unique hidden name; sync the file, exclusively rename it to the asset UUID, verify name/descriptor identity, and sync the containing directory before returning. Sync parent directories when creating storage folders. Cleanup verifies the owned file identity before unlinking. Interrupted writes may leave only unreferenced encrypted files. Asset publication precedes any metadata reference; transaction integration belongs to the next subsystem.
- Missing assets return nil. Tampering and unsafe entries throw; they never become a blank successful image. Removing one explicit UUID cannot remove unrelated entries. Private assets exist only in the store's memory and disappear with it.

## Follow-on editor/capture contract

Native tab routing must resolve the board only in the tab's actual profile, including restoration, split panes and window transfer; ordinary websites/extensions cannot manufacture a privileged route. Private canvases and captures stay in memory. Website-data clearing cancels pending captures but preserves saved canvases; deleting a profile removes its canvas assets. Capture callbacks are bound to the original document/profile/window and may not publish after navigation, transfer, deletion, clear or shutdown. Capture what is actually visible, including Reader, without borrowing or weakening fullscreen WebKit ownership. The editor needs notes, links, images, drag/resize/layering, zoom/pan, undo/redo and export, with native text editing and accessible controls. Those behaviors require a separate implementation plan and live acceptance before claiming Easels ready.

## Acceptance for this subsystem

Real encode/decode/profile-merge checks prove retention, malformed-input rejection and optimistic edit isolation. Real filesystem checks prove encryption, permissions, bounded input, authentication binding, lease invalidation, safe missing/removal behavior and private zero-I/O operation. Integrate these checks into the repository's normal build checks. Compile the application against the new core; run the existing core regression checks. No release or main integration before the editor/capture work and review.
