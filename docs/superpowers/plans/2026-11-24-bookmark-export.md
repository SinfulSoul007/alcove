# Bookmark HTML Export Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Export the selected normal profile's saved pages as portable bookmarks HTML.

**Architecture:** A bounded BrowserCore serializer produces immutable data and counts. A window/profile-bound native save action passes accepted bytes to the existing output coordinator, whose pending-write and Quit handling are shared with page output.

**Tech Stack:** Swift, Foundation, AppKit, UniformTypeIdentifiers, existing output environment.

**Spec:** `docs/superpowers/specs/2026-11-24-bookmark-export-design.md`

## Global Constraints

- macOS 14+, no new dependencies or metadata format change.
- Export Favorites/pins/folders/bookmarks for exactly the captured normal profile; omit Today/history/archive/deleted Spaces/credentials.
- Netscape bookmarks HTML, UTF-8, maximum 64 MiB, maximum 32 nested user folders.
- Explicit HTML save sheet; atomically write accepted immutable bytes off the main thread.
- Preserve accepted-write tracking through window closure/Quit; cancellation or unavailable source prevents acceptance.
- Keep public 0.20 artifacts and tag unchanged; do not count unverified native behavior as complete.

## Review Focus

- Profile changes while a sheet is open must never substitute the newly selected profile.
- Home addresses/custom names and collapsed/empty folders must survive export.
- HTML metacharacters and invalid/credential-bearing links must not produce executable markup.
- Closing the window or receiving duplicated native callbacks must not duplicate output or leak a source label in errors.
- Accepted output must keep Quit waiting and propagate write failure.

### Task 1: Portable serializer

**Files:** Create `Sources/BrowserCore/BookmarkHTMLExport.swift`, `scripts/BookmarkHTMLExportChecks.swift`; modify `scripts/build.sh`.

**Interface:** `BookmarkHTMLExport.init(spaces: [Space], favorites: [Tab], bookmarks: [PageRecord]) throws`; exposes `data: Data`, `bookmarkCount: Int`, `skippedLinkCount: Int`.

- [x] Add actual serializer/import round-trip checks for grouping/order, saved addresses/names, nested/collapsed/empty folders, duplicate policy, unsafe links/escaping, malformed folder cycles, dates, empty output and resource bounds. Missing serializer is the initial RED.
- [x] Run and retain RED; implement the smallest bounded serializer using the existing repaired `SidebarFolderTree`.
- [x] Run the focused check via `./scripts/build.sh bookmark-export-core-test`; integrate it into the complete test command.
- [x] Commit passing serializer and checks.

### Task 2: Native export and accepted output

**Files:** Create `Sources/Browser/BookmarkExportActions.swift`, `scripts/BookmarkExportStoreChecks.swift`; modify `Sources/Browser/BrowserAppDelegate.swift`, `Sources/Browser/PageOutput.swift`, `Sources/Browser/PageOutputNative.swift`, `scripts/build.sh`.

**Interfaces:** `BrowserStore.bookmarkExportSource(profileID:) throws -> BookmarkExportSource`, whose `render()` runs off the main thread; `canExportBookmarkHTML`; `AppDelegate.exportBookmarks()`; coordinator `writeAcceptedFile(_:to:failureMessage:)` tracks immutable accepted data without requiring a website. This rendering-interface adjustment is recorded in the execution ledger.

- [x] Add owned profile-isolation/locked/private/pending/closed-source checks and accepted generic-write lifetime/failure/duplicate-callback tests. Observe expected failures before implementation.
- [x] Implement one-profile snapshot, menu validation and explicit save sheet; accept only a current, eligible originating window/profile.
- [x] Implement generic accepted-write tracking through the existing writer/waiter environment without changing page capture semantics.
- [ ] Run focused native gates in the VM, compile both architectures, run the complete suite once on the final reviewed candidate; keep unavailable live dialog gates explicitly open.
- [ ] Record actual evidence, request one bounded review, fix material issues with failing/passing checks, commit. Update user-facing docs only to claim verified behavior; do not publish an unqualified build.
