# Website fullscreen

## Intent and current evidence

The browser must support genuine website/video fullscreen while preserving the live page, its form/scroll/media state, the correct browser window/profile and ordinary commands. This is part of the user's full Arc/browser objective, not a substitute for PiP, visual QA or Chrome-extension compatibility. The user has authorized autonomous implementation and asked to avoid repeated design questions.

Base is the independently reviewed combined Reader/export 0.21 candidate `57a11f4462204eb380e28a9ab37ea1e7638313c9`, whose complete hosted run `45557540457` is separate and still pending. Work uses an existing clean linked checkout on `feature/website-fullscreen`; it does not alter that candidate or any release.

The app never enables `WKPreferences.isElementFullscreenEnabled`, whose documented default is false. The SDK says WebKit replaces a fullscreen web view with a placeholder, moves it into another window and later restores it; `fullscreenState` is KVO compliant. Current `EdgeToEdgeWebHost.setContent` would reclaim a borrowed view on a SwiftUI update. AppDelegate recognizes only its own primary/Quick windows, so framework fullscreen windows also require correct logical ownership. Existing direct discard/transfer, page prompts and overlays need an exit/restoration boundary.

## Approach and constraints

Use WebKit's public element-fullscreen APIs and actual native transitions. A per-view presentation/residency coordinator observes `fullscreenState`, captures the originating logical window/profile/presentation, remembers the latest intended host and cooperates with normal view-move notifications. It never steals a view from WebKit during entry/fullscreen/exit. Once WebKit restores the view, it reconciles the latest valid host and viewport without reloading or duplicating the document.

This is chosen over a custom enlarged/cropped page, which would not provide genuine fullscreen, and over merely flipping the preference, which breaks ownership. No private APIs, process instrumentation, global input control, sandbox exceptions, JIT changes or app-signing changes are needed. Preserve macOS 14+, both architectures, the current six entitlements and the separate custom-engine signing gate. Enable the capability only for real website configurations; inert Reader and internal parsing/manager views retain their restrictions.

## Required behavior

1. Normal tabs, split pages, primary Peek, Quick Browse and Quick Peek, normal/private contexts and website popups support the genuine API. Record actual WebKit state/window/placeholder evidence for both a generic element and video. If a video presentation path differs, investigate it; a div-only result does not certify all media parity.
2. The exact WKWebView, document token/identity, unsaved form, scroll and navigation history survive entry, SwiftUI updates, window/host resizing and exit. No presentation claims a new document merely because WebKit moved the view. Replacing a host or handing off the page while fullscreen exits safely and eventually mounts the latest owner once.
3. Logical window/profile routing remains correct while the physical key window belongs to WebKit. Escape first exits website fullscreen without closing the underlying Peek/tab. Cmd-W exits then closes the captured page/window with existing empty-window semantics; the app remains running. Address/find/Reader/printing and other chrome actions leave fullscreen before presenting native UI. A stale action never retargets another profile, document or window; only restore focus when the originating presentation remains current and foreground.
4. Coalesce exit requests and complete/cancel pending operations once. Distinguish document-bound operations from presentation/window actions. Navigation invalidation, profile clear/delete, view transfer, popup/Quick/primary close and shutdown cancel stale work. Closing a fullscreen page must not leave a framework window, live retired page or owned website store behind. Preserve existing durable failed-clear/recovery semantics.
5. Navigation protection and website dialogs/media-permission sheets remain visible and correctly source-bound. Exit/restore before capturing a new native prompt/warning target. Existing stale prompt results still fail closed. Native sheets on any active presentation block conflicting commands. Extension window/tab ownership and focus reporting continue to describe the logical browser window.
6. A fullscreen page is protected from idle suspension/archive while presented, including static content with no playing media. Explicit close/clear still work. Existing normal OS-window fullscreen, toolbar/sidebar geometry, Reader lifecycle, split drop and page-output behavior remain intact.
7. Verify actual native transitions using owned local HTML/video and scratch state on a hosted Mac while the dedicated VM remains locked. No real browsing data, Keychain or user desktop is used. Keep bounded timeouts, honest failure markers and owned cleanup. Actual native/AX/animation/minimum-OS/Intel/installed-app verification remains distinct from compilation or a model test.

## Acceptance and open broader work

A green preference flag or simulated reparent is insufficient: require actual native entry/exit, source preservation, stable remount/geometry and correct interaction/lifecycle tests. Then run appropriate existing chrome/Reader/Peek/Quick/split/profile/output regressions, both optimized builds/package gates and one fresh whole-branch review with one material fix pass. This feature is not published until its own gates pass. PiP/Mini Player, the full Arc inventory, broad extensions, sync/assisted workflows and the rest of `docs/goal/acceptance.md` remain part of the active goal.

Sources: [Apple fullscreen preference](https://developer.apple.com/documentation/webkit/wkpreferences/iselementfullscreenenabled), public SDK `WKWebView.h` fullscreen-state/placeholder and `closeAllMediaPresentations` documentation. All required APIs predate the existing macOS 14 floor.
