# Shared-window verification

The dedicated Mac ran window-group-test (22), window-model-test (47), writer-test (27), startup-test (40), space-test (53), quick-store-test (30), store-test (37). All 256 assertions passed without compiler diagnostics. The previous model checkpoint also passed 34 existing core assertions.

The writer retains the only encrypted metadata store, key lookup and metadata lease. Window-local selections, sidebar and Find stay independent. Tab, Space, profile and preference changes appear in both projections. Persisted transactions reject an older prepared snapshot. An interrupted writer leaves the previous state visible and pauses saving for both windows. Closing a primary window preserves its surviving peers and compact pages. Reopening a compact URL surfaces its existing window.

These checks exercise grouped stores and the owner directly. Native window and command integration remains in Task4. Task3 covers live WebKit handoff, cross-window page protection during profile operations, and persistent window restoration. Public 0.9.1 uses the previous single-window path.
