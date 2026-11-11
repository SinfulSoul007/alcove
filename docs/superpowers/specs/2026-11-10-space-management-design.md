# Safe Space management

Complete the everyday Space lifecycle: preserve the existing name/icon controls in Customize, add durable rename/icon operations and quick access, reorder, delete/recover, and explicitly permanently remove deleted snapshots. Keep the full original Arc-like browser goal intact. User has opted into autonomous inline work in the existing main checkout, commits/pushes, native testing and unsigned previews; no repeated design/mode/permission gate.

## Approaches and choices

Use encrypted per-profile Recently Deleted Space snapshots rather than irreversible deletion or merely scattering tabs into the existing tab archive. This preserves names/themes/pins/order and gives discoverable recovery. Native menus plus an in-window Space manager with horizontally arranged themed cards and native tab previews provide quick actions and an accessible overview; sidebar/card drag/drop and move controls share the same durable operations. Keep existing web views mounted and shift the current pane beside the manager, respecting reduced motion. This follows the directly inspected Arc Manage Spaces UI; no Arc code/assets are copied. These are builder choices under the user's opt-out.

Use an advisory profile-directory ownership lease for live normal browser writers rather than changing encryption keys or silently merging conflicting sessions. The lease is shared inside one process and exclusive between cooperating processes. BrowserStore acquires it before Keychain/document access and holds it until shutdown; MetadataStore.save also participates. A busy secondary instance stays responsive with Try Again and Private Window, without requesting Keychain or opening normal website stores. The empty lock file is never unlinked; closing/crashing releases the OS lock. This coordinates Alcove instances, not arbitrary non-cooperating programs or generic stale snapshots created in one process.

## Data and behavior

- Add optional deletedSpaces records to each encrypted profile library. Record ID, complete Space snapshot, original index and deletion date; omit profile-global Favorites from the snapshot, since they remain live in their profile library. No automatic expiry or silent dropping.
- Upgrade document format3 to4 before exposing recovered identifiers. Versions1–3 migrate; future versions reject. Older Alcove refuses format4 instead of silently discarding the new recovery records on downgrade. No Keychain namespace/key/ACL change.
- Rename/icon/reorder preserve Space/tab/profile IDs and mounted pages. Names trim whitespace, reject empty, cap60 characters; icons use curated SF Symbols, preserving an existing unknown icon until explicitly changed.
- Deletion persists the snapshot and replacement selection before tearing down only Space-owned pages. Prefer another Space in the same profile, otherwise a neighboring Space; deleting the last Space creates a blank Personal Space in that same profile. Cookies and profile Favorites are kept. Unsaved forms cannot be recovered and deletion confirmation says so.
- Restore returns the snapshot to its original order, retains its owning profile, repairs ID collisions without affecting existing pages, and removes the recovery record in the same save. Missing/busy/clearing/deleting profiles block recovery, with no account fallback. Routes targeting a deleted Space stay unavailable until that exact Space is restored; do not silently redirect them.
- Undo via a visible action restores the last deleted Space; Recently Deleted supports recovery after relaunch. Permanent deletion requires explicit native confirmation. Profile-data clearing also removes its deleted Space snapshots; deleting a profile removes its library.
- Private Spaces support temporary rename/reorder/delete/undo without persistent metadata or keys; closing the private session destroys its deleted snapshots.

## UI and constraints

Manage Spaces is reachable from Space title menu, footer menu, per-Space context menu and command palette. The manager has Open/Recently Deleted sections, fixed card headers/footers, scrollable native previews, visible rename/icon/save/select controls, move controls and recover/delete actions, fits short windows, and has keyboard/accessibility labels. Existing Customize fields use durable operations. Preserve position-derived default icons before reordering/deletion so icons stay with their Spaces. Sidebar order updates immediately after durable success. Theme editing continues using existing customization.

macOS14; existing exact six entitlements; stable Visual Four identity. Version0.8.0/build15, candidatev0.8.0-preview.1. One fresh whole-plan final reviewer, one verified fix pass, no second review. Full local checks, both optimized builds and exact-source CI/download-back verification precede distribution. Existing unsigned labeling stays accurate. Broader extensions/sync/media/visual/performance/security gates remain open.
