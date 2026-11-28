# Interactive Easel Live Captures

## Intent and authority

The user's active scope is the complete Arc-style browser, including its best features, native polish, protected local data and efficient resource use. They delegated routine product/implementation choices and asked for uninterrupted execution. These choices are the executor's calls, rather than individually approved preferences. The existing 0.22.1 release candidate remains frozen at fb3b90b; this feature develops separately.

Arc's [first-party Live Capture reference](https://start.arc.net/paint-the-internet), checked2026-11-28, describes capturing part of a page and clicking Play to interact with the webpage inside an Easel. A periodically refreshed image does not meet that behavior. Alcove already has protected Easel images, a crop preview, actual page snapshots, drawing, history and native canvas cards. It has no interactive capture implementation yet.

## Result a person gets

The current page-capture sheet adds a Live option for an ordinary HTTP(S) page. Its crop preview and destination controls remain familiar. Saving creates a card with the chosen source region, its original site attribution and an offline preview. Nothing loads from the network merely because the saved Easel is opened.

Play opens a real profile-bound webpage inside that card at the captured viewport, zoom and scroll. Links, buttons, text fields and scrolling work in the clipped webpage. Native card controls remain outside the web content: Play/Stop, Open Source and Update Preview. The browser's existing network protections, permissions, supported extension hosting and download behavior still apply. The live origin is always visible when navigation changes it.

Stop closes that live page and returns to the saved preview. It follows the browser's ordinary page-close lifetime; input in that webpage is runtime state, not a saved note. Stop's accessible label and tooltip explicitly say it closes the live page. Selecting or drawing on the canvas must not accidentally edit or click the webpage; ordinary interaction is enabled only after Play, and the native move/resize handles remain available. Canvas tool changes return input to the canvas without silently submitting a form.

Update Preview explicitly captures the current live view into the encrypted asset store. Ordinary typing/clicks do not continually save website pixels or form values. Navigation inside a live page does not silently rewrite its saved source definition; a separate explicit Replace Source action can adopt the current page/crop using the same revision-checked capture flow. Open Source uses the saved source URL. The live origin badge uses the current actual URL.

## Approaches

1. Refresh the saved raster on a timer. Cheap and compatible with image cards, but cannot satisfy in-card interaction; rejected.
2. Reparent the original tab's web view into the card. Preserves its form state, but makes the capture depend on the source tab/window, conflicts with simultaneous source use and the existing single-view handoff lease; rejected.
3. Create an independent real webpage in the selected profile, registered through the existing browser web-view lifecycle, and clip its viewport inside the native card. Chosen. It preserves the original page, uses the existing browser policies and supports multiple independent cards. It requires explicit capture-page identity and lifetime integration; an unmanaged WKWebView or a fabricated Quick Browse record is unacceptable.

## Persistent values and capture transaction

Add immutable Codable/Equatable/Sendable `EaselLiveCapture` content containing:

- The existing preview asset UUID and pixel width/height, with the same image bounds:1...16384 per side and40,000,000 pixels maximum.
- HTTP(S) source URL, at most8192 UTF-8 bytes, without user/password, controls or invalid port; nonempty source title at most256 UTF-8 bytes. Reuse the existing URL/title validation policy.
- Captured viewport width/height in CSS view points, each finite and1...8192; captured page zoom finite and0.5...3; scroll x/y finite and0...16,777,216.
- A normalized crop rectangle with finite x/y in0...1, width/height greater than zero, and right/bottom no greater than1. Decode through the same validating initializer.

Use a dedicated typed content case and metadata format11. Existing format10 documents remain readable; older readers must refuse editing a newer format. Retain the500-item and16384 canvas bounds. Live preview assets participate in the same reference accounting, recovery, profile erasure, offline export and quotas as image assets.

The capture coordinator snapshots document/presentation/profile generation, URL, viewport, scroll and page zoom around the actual snapshot. Reject capture publication if the source changes or geometry moves before completion; retain the existing20-second deadline and crop/destination behavior. A Reader-rendered page remains eligible for static capture. Its live option is unavailable because an isolated article is not the original website.

The chosen crop, viewport metadata and normalized fallback image are one immutable pending capture. Commit their asset and card atomically through the existing revision/ownership transaction. Failure, cancellation, profile retirement or a changed destination must not publish an orphan card or asset. History/recovery must preserve distinct captured definitions and fallback assets.

## Real page ownership

Create a runtime capture-page record keyed by a fresh UUID, with owner Easel tab ID, item ID, profile ID, store/window lease and generation. It supplies a genuine ephemeral BrowserCore.Tab value for the browser's existing `tab(id)` and profile lookup. Its WKWebView lives in the normal `views` registry and uses the normal configured website data store, extension controller, navigation/UI/download delegates, document/presentation identity and observation cleanup. It is not inserted into Today, pins, Favorites, history restore or Quick Browse metadata.

This explicit runtime page role must be recognized by all actions that currently assume a registered view maps to a saved sidebar tab. Title/URL observations update runtime page state, rather than saving a new sidebar item. Ownership tests must prove that register/update/discard, process failure, profile clear/delete, extension erasure, website prompts, media inventory and app shutdown include these pages. Stale async work cannot resurrect a stopped or retired capture.

A capture is visible/current only when its owning Easel tab has the current lease, its matching item still exists, its native host is attached, and the corresponding canvas pane is visible. Keyboard focus additionally identifies the particular playing card. Existing privileged actions must use that verified source; visibility in a background Easel is insufficient to grant a focused-page permission.

Supported extension injection uses the existing profile host. Capture pages get real runtime tab bindings when the host needs one; never impersonate another website tab or expose the native Easel route as a website. Query/reload/navigation/close act on the capture page, with close stopping playback rather than deleting the card. Any child-page operation that cannot preserve its owner/profile must return an explicit unsupported error instead of mutating the parent or a different tab. Full Chrome API compatibility remains the separate existing engine objective.

## Native presentation and input

A native clipped web host uses the saved viewport size and zoom, then restores the captured scroll after navigation. Its clip contains exactly the selected region, with geometry transformed through native view bounds so mouse, text, wheel and accessibility coordinates remain correct at canvas magnification0.25...2. Resizing a card fits that same crop uniformly and letterboxes when the aspect ratio changes; it does not silently select a different region. Page reflow or dynamic content can change what appears at a coordinate after reload; Replace Source/crop is the explicit repair, and the saved preview remains available.

The web host must remain stable through autosave, selection and layout redraw. Drawings above it must keep correct hit testing and stacking. Native controls must fit the40-point minimum item frame via a compact overflow menu, with accessible Play/Stop/Open Source/Update Preview actions. Actual user-input checks must verify a button and Unicode form entry at both fractional and enlarged canvas zoom; calling JavaScript to simulate those interactions is insufficient.

Each played capture is its own page. Switching to another tab/Space does not recreate a still-owned page; existing memory/media policy may suspend eligible inactive pages, with state and limits shown honestly. Cold reopen restores offline previews, never a set of automatic network loads. Stop, item removal, owning-tab closure, profile retirement and shutdown retire the page through one idempotent path. A failed document edit must not close a still-saved card's live page.

Moving the owning Easel tab to another normal window transfers its live child view/document bindings with the lease, preserving runtime form state. Two separate Easel tabs displaying the same board have independent live page instances in the same profile. A view is never mounted in two hosts. Native website fullscreen must return to the exact capture host, or finish retirement, before the host disappears; late callbacks cannot restore an obsolete host.

## Private data and exports

Normal definitions and preview assets retain the existing encrypted profile storage. Private capture definitions/assets/pages remain in memory and use the private website data store and private extension-host policy. Private Play never waits for or creates the normal metadata key. Clear/delete/retirement revokes capture pages and pending publications in the owning profile only.

PNG and standalone HTML use the immutable saved fallback preview and source attribution; they embed no active webpage, remote scripts or live network references. Export remains16MP/8192px PNG and128MiB HTML, with the existing CSP, explicit native destination and accepted-output lifetime. A missing fallback is an explicit error, not a network fetch during export. Update Preview/Replace Source use normal history so Undo restores the earlier preview/definition without reviving a stopped page.

## Required qualification and boundaries

Pure tests cover validating/decoding bounds, format10 migration/newer-reader refusal, revision edits, reference accounting and inert exports. Native checks cover captured geometry, atomic save/rollback, runtime ownership, shared extension/protection paths, stop/retirement, real clipped input and window handoff. Actual normal/private app tests cover Play, typing/clicking, crop at zoom, Stop, protected cold reopen, native controls and exported fallback. Use only the dedicated VM or hosted macOS for GUI execution; no host desktop fallback. One whole-feature review and exact-source package qualification follow implementation.

This feature does not claim collaboration/cloud sharing, a full Chrome engine, original-uBlock support, Apple signing/notarization, physical-hardware/VoiceOver/performance certification or a completed Arc inventory. Those remain active requirements. No product code has been written for this design yet.
