# Quick Browse and external links

The full goal in docs/goal/acceptance.md stays active. Published 0.5 is verified progress, not full Arc parity. The user authorized continuous implementation, commits/pushes and previews in Programming/browser and opted out of repeated design questions. Keep AppKit/SwiftUI and system WebKit on macOS 14+.

Quick Browse supplies Arc's Little Arc workflow: external web links open in compact windows, repeated links resurface their existing window, and the live page can move into a Space. Use independently written UI and Alcove naming. The shared profile store owns every page; no second normal metadata writer is introduced.

## Ownership and recovery

A profile library has optional `quickPages: [QuickPage]`, whose record contains a Tab, an optional intended Space UUID, openedAt and lastActiveAt. The library's profile ID is authoritative. Quick pages do not appear in a Space's Today/pins/Favorites until promoted, and Space reassignment cannot change their profile. They survive save/relaunch. Private owners hold them only in memory and never load normal registry, domain choices or metadata. Private promotion remains within its own private owner.

Metadata format 3 extends format 2 inside the existing `session-v2.sealed` file. The filename marks the compatibility fork from pre-profile binaries; the document version is independent. Readers accept nil/1/2/3 and write 3. Older 0.5 readers reject format 3 without modifying it. Retain the existing pre-profile encrypted recovery copy. Repair duplicate quick/live/Favorite UUIDs without sharing a WKWebView across profiles or dropping page content; clear invalid intended Space references. Merge duplicate libraries without losing quick records.

## Page lifecycle

External URLs must be valid http/https with a nonempty host. Choose a remembered exact hostname profile when present; if that profile is paused, refuse the link with a visible explanation until it is available. Without a remembered choice, use the normal owner's active available profile; never route through a currently focused private window. Existing same-URL windows reuse only within that owner and profile. Keep an opt-out in Settings that opens external links directly in a Space. Unavailable profiles never silently use another persistent cookie store.

Normal creation, promotion, profile change, close/archive and auto-archive persist a candidate before changing native pages or exposing windows. If saving fails, preserve the live page/old records and visibly pause saving. Navigation/title updates retain the existing debounced save semantics; failed-save Unlock merges unsaved quick records for known profiles without resurrecting closed pages. Locked startup rejects creation until Unlock rather than create an unrecoverable normal store. Private operations bypass normal persistence entirely.

The views registry tracks quick Tab UUIDs as well as Space tabs. History, popups, permission prompts, favicon requests and navigation callbacks resolve the owning profile directly. Unknown/stale pages are rejected. A popup from a quick page stays in Quick Browse with the opener's profile. Visible quick windows are excluded from background-tab suspension. Each primary/quick window has its own independent, ephemeral Peek context; opening or closing another window’s Peek must not blank its form. Shift-click Peek appears over its originating quick window, and promoting that Peek uses its actual profile, never whichever Space became active later.

Promotion to a Space of the same profile moves the existing Tab and WKWebView, preserving DOM, forms, scroll, navigation history and website storage. Cross-profile promotion or profile selection requires explicit reload consent, commits ownership first, and then recreates the page without copying cookies. Choosing another profile may remember the current exact hostname; revalidate the original page/profile/URL after a modal. A profile with no Spaces can receive a new Space when promoting. Existing quick pages keep their profile if their intended Space changes or disappears.

Closing a nonempty quick page archives its last metadata in that profile with `archiveSource = quickBrowse`; private close keeps temporary archive only. Blank quick windows leave no archive record. The Library can filter Quick Browse archive entries and restore into a Space or another quick window. Default auto-archive is six hours of inactivity with Off/6/12/24 hour options. Never auto-close the focused quick page, a loading page, active media playback/capture, or a page while saving/profile operations are paused. Ask WebKit for playback state only when an expired live page is being considered; bound unresponsive probes, keep unknown pages open, and revalidate profile, native identity, URL, activity and current ownership before committing. Active playback/capture advances activity without invalidating the global UI. Explicit close may lose forms, like closing a normal tab; the auto-archive preference explains this.

Profile clearing removes quick records and remembered hostname choices for that profile together with its other browsing records, releases native pages and closes their windows. Deletion removes domain choices and cannot leave live quick pages attached to a deleted store. Retries must retain newly queued records after the initial clear reset.

## Window and keyboard behavior

Use a compact native resizable window with traffic lights, back/forward/reload, editable address, profile selector, progress, find, and an Open in Space menu. It uses the existing theme, motion preference, reduced-motion setting and accessible labels. Minimum size is 480 by 360; ordinary starting size is 760 by 600, clamped to the screen. Native visual/animation/resizing and keyboard evidence remain pending app access; compilation cannot satisfy that gate.

Each normal/private BrowserStore has one window owner that holds a primary-window lease and quick-window leases. Closing the primary window while quick windows remain keeps that same store alive; reopening the primary uses it. Closing the last window shuts the owner down once. Promotion establishes a primary lease before dismissing the quick window. Never create competing normal stores or lose the last writer on a close-order race.

Option-Command-N opens Quick Browse; move New Space to Control-Command-N to avoid the collision. Command-L focuses the active quick address; Command-T in a quick window starts a new quick page for that same profile. Command-W closes the active quick window. Back/forward/reload/find/zoom/bookmark commands act on its actual page; sidebar/split/pin controls remain primary-window controls. The Window menu can show/hide quick windows. External windows and popups can be restored on launch, without interrupting first-run setup with update checks.

## Verification

Core checks cover old-document migration, UUID repair, hostname normalization/selection, profile fallback and lifetime/age policy. Store checks exercise durable creation, same-URL reuse, archive/reopen, same-page identity on promotion, cross-profile consent, profile reassignment, failed saves, Unlock merging, clear/delete, private nonpersistence, popup/Peek ownership and window-owner close ordering. Real same-origin WebKit fixture pages prove cookies/localStorage separation and DOM/form/navigation retention through same-profile promotion. Only random disposable profile stores are used and removed.

Official Arc behavior reference: https://resources.arc.net/hc/en-us/articles/20498377604887-Arc-for-macOS-2023-Release-Notes (same-link resurfacing, remembered domain profile, multiple windows, six-hour archive, tab handoff). UI implementation and metadata layout are Alcove choices, not claims about Arc internals.
