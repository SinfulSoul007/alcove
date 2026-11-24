# Bookmark export candidate verification

The developing source adds **File → Export Bookmarks HTML…**. The public 0.20 tag and downloads are unchanged. This increment does not complete the full browser goal.

The selected normal profile exports Favorites, pinned pages grouped by Space and complete nested/empty folders, followed by library bookmarks not already represented. Saved home addresses and custom/pinned titles are retained. Explicit saved copies in different folders remain. Today, history, archives, closed/deleted tabs, other profiles, website storage and credentials are excluded. Unsupported and credential-bearing addresses are skipped; their count is shown before acceptance. The UTF-8 Netscape HTML output is bounded to 64 MiB and 32 nested user folders, with no partial result on failure.

Preparation uses immutable value snapshots on a background task. The native HTML save sheet identifies the captured profile, page count and skipped links and explains that the file is readable outside metadata encryption. Cancelling, closing or replacing the source window, locking/erasing the profile or removing the captured saved links prevents unaccepted output. Selecting another profile keeps the original target. Once accepted, immutable bytes use the existing atomic writer and participate in output/Quit draining even after the source window closes. Duplicate native callbacks cannot write twice.

## Evidence

- `./scripts/build.sh bookmark-export-core-test`: 19 checks, zero failures. Actual bytes round-trip through Alcove's HTML importer, preserving saved addresses, UTF-8 names and nested/empty folders. Controlled cases cover markup escaping, unsupported links, credential rejection, malformed folder cycles, dates, empty profiles, depth and size bounds. The initial test failed because the serializer did not exist. HTML Tidy's formatting newline is normalized only when comparing visible heading names; hierarchy and imported data are checked separately.
- Native owned VM fixture: 33 checks, zero failures, with exact compiled source hashes and temporary-data cleanup verified. It uses real BrowserStore profiles, metadata with its own temporary key, the production export/output controllers and actual temporary-file writes. Only the OS chooser and writer timing are substituted to hold acceptance/completion callbacks. No website or visible save dialog is opened by this fixture.
- The expanded native witness first produced exactly one failure among 33 checks: removing a bookmark while the dialog was open still allowed the old bytes to be accepted. The retention guard now revokes that request; the unchanged witness passes. Changing the selected profile, dialog cancellation/close, replacing the source window, duplicate callbacks, accepted writes through close, failure propagation to Quit waiters and non-file destinations are covered.
- Strict arm64 compilation of the complete app source and native witness passed without diagnostics. Core value types used by background preparation have compiler-checked `Sendable` conformances. No metadata-format change or additional dependency is introduced.

## Open gates

Fresh source review, complete hosted source suite, both optimized architecture builds, bundle/package checks and live native save-dialog/keyboard/accessibility testing remain pending. The CI timeout is 105 minutes because the previous complete suite took 88 minutes 6 seconds under its 90-minute cap and this increment adds an app-linked native check; no existing gate is removed.

The automated fixture does not establish desktop visual fidelity, actual Save/Cancel button input, filesystem permission behavior across every destination, broad compatibility with other browsers' importers, minimum-OS or real Intel hardware behavior. Prepared snapshots intentionally omit saved pages added after preparation; retry export to include later additions. Live tab navigation does not replace saved pin home addresses in the file.
