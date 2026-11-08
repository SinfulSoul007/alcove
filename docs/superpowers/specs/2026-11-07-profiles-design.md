# Isolated browser profiles

Continue the full browser goal in docs/goal/acceptance.md. Profiles close one material security/workflow gap; they do not replace the outstanding Arc UI, animation, distribution or compatibility requirements. The user has instructed continuous implementation in the existing native Mac project and authorized commits/pushes.

## Behavior

A profile owns website logins/storage, Favorites, bookmarks, history, closed tabs and archive. Multiple Spaces may use the same profile. Existing Spaces and records migrate to a default profile using WebKit's existing default data store so website logins survive. New profiles use macOS 14's persistent named WebKit stores with a saved, valid UUID. Private windows use only their own nonpersistent store and temporary records.

Profile management supports creating, renaming, assigning a Space and deleting unused profiles. Creating a profile opens a new Space for it. Assigning a different profile preserves URLs and warns before reloading pages with the other profile's logins; unsaved page state cannot be transferred. Deleting a profile requires moving its Spaces first and an explicit confirmation; default can be cleared, not removed. A durable deletion-pending flag prevents a crash or failed final metadata save from recreating a deleted store. Failed deletion keeps a recoverable entry and offers retry.

Popups, background navigation/history, Peek and split panes inherit the originating tab's profile. Moving/dragging a tab between different profiles requires confirmation and recreates its page with the destination store; cookies never move. Late callbacks from discarded pages cannot alter replacement tabs. Favorites and command-tab results stay within the selected profile.

Clearing website data acts only on that profile, resets its tabs, and keeps unrelated profiles/Spaces and bookmarks. Downloads remain on disk. Normal encrypted metadata holds the profile registry and per-profile library records; WebKit website databases remain system-managed, outside metadata encryption. Profiles are organization and website-storage boundaries within one macOS account, not protection against another person using the unlocked app.

## Implementation choice

Keeping one store for all Spaces fails isolation. Giving every Space an independent store prevents intentional shared logins and is unlike Arc profiles. Use named profiles with explicit Space assignments, and retain the legacy default store. This is an implementation choice under the user's instruction to continue building without repeated design questions.

The encrypted document retains its old `library` field as the default-profile compatibility snapshot, adding optional profile/library arrays. Missing arrays load old data. A library array is authoritative for a profile it contains; do not merge its compatibility snapshot twice. Unknown valid profile identifiers are recovered with that same identifier, never silently mapped to another profile's cookies. Reject/remap the all-zero UUID before calling WebKit. Preserve colliding records when repairing duplicated libraries.

Profile creation/assignment persists the candidate metadata before exposing a new store or discarding live pages. A save failure preserves the old live state and pauses saving. Deletion writes a tombstone first, releases related WebKit objects, removes the named store, then removes registry/library metadata; final-save failure leaves a retryable tombstone. A pending/unavailable profile must never fall back to another profile's persistent store.

## Verification

Core checks cover old-document migration, default compatibility snapshots, missing/duplicate/invalid IDs, library preservation and separation. Store checks cover encrypted relaunch, Favorites/history/archive/close/popup/Peek/move ownership, private nonpersistence, failed persistence and deletion retries. Real WebKit cookie stores and disposable fixture pages prove website isolation and store-ID reuse. Native profile UI, keyboard, sizes and visual verification remain required; do not infer them from compilation.

Primary reference: https://webkit.org/blog/14423/building-profiles-with-new-webkit-api/
