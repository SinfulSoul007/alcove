# Sidebar Organization Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans inline. Existing main-checkout/autonomous execution consent applies. No repeated mode/design approval or per-task reviewers; preserve the single final whole-goal review workflow.

**Goal:** Make window/tab closure and saved-tab organization work as the user requested.
**Architecture:** Existing durable Store transactions feed optional per-Space folder definitions and distinct bounded sidebar regions; native menu actions close the correct source window through its owner lifecycle.
**Tech Stack:** Swift, BrowserCore, AppKit, SwiftUI, WebKit.
**Spec:** docs/superpowers/specs/2026-11-11-sidebar-organization-design.md

## Global Constraints
- Keep macOS14, six entitlements, Keychain policy and Visual Four path/bundle ID unchanged.
- Work in the authorized main checkout; preserve all in-progress extension changes and ledgers. Priority steering does not complete/abandon that plan.
- Developing metadata5 retains all profile/controller/grant fields; optional folder definitions coexist with legacy tab.folder/collapsedFolders. No dummy website records.
- Tests/builds sequential. Freeze product/test inputs during complete gates. Only owned data/hidden native fixtures; never Arc profile files or vendor extension execution.
- Native app lifecycle via CUA, same stable app identity. Existing0.8 rollback material/public assets stay protected.

## Review Focus
- Cmd-W must not quit the app, target another window, remove saved pins or reload another split pane.
- A bookmark/folder operation after profile/Space changes or failed saving must not publish to another account or lose a live form.
- Empty, renamed and removed folders must survive reload appropriately without orphaning or deleting URLs.
- Crowded Favorites/Pinned/Today at short heights and large text must keep each region and footer reachable.
- Pending Keychain/profile operations/private sessions must remain usable and preserve their data boundaries.

### Task 1: Window closure and durable saved-tab/folder operations
**Files:** BrowserAppDelegate.swift, BrowserStore.swift, QuickBrowseActions.swift, BrowserActions.swift; new SidebarOrganization.swift; BrowserCore/Session.swift; scripts/SidebarOrganizationChecks.swift and build.sh.
**Interfaces:** Space.folders optional ordered string definitions and folderNames legacy union; createTabFolder(name:in:), renameTabFolder(_:to:in:), removeTabFolder(_:in:), moveTabToFolder(_:folder:in:) transaction methods; closeTab native menu routing; bookmarkWebsite retains live main view while adding pin.
- [x] Step1: Add owned menu/Store/schema regressions: blank and last-tab window close without quit, remaining/split tab retention, pinned definition retention, panel/Peek precedence, empty folder round trip, legacy memberships, rename/remove/move/profile/private/failed-save cases and bookmark-to-pin live view. Run focused sidebar-organization-test. Expected: meaningful missing behavior/interface RED, no real profile access.
- [x] Step2: Implement native source-window close policy and atomic folder/bookmark methods with captured IDs. Expected: focused checks PASS, zero diagnostics; pinning does not replace the live view.
- [x] Step3: Run focused startup/lifetime/Favorites/Quick regressions, ledger all rulings. Expected: PASS, no regression. Commit with Task2 UI after full gate to keep this increment coherent.

### Task 2: Separate saved-tab sidebar and native verification
**Files:** BrowserUI.swift, CommandActions.swift, BrowserActions.swift, folder presenter helper; scripts/SidebarOrganizationLayoutChecks.swift; release/report docs.
**Interfaces:** Pinned region uses folderNames and Store mutations; Today has independent scrolling; header New Folder and tab/folder menus/drop targets call captured-Space transactions.
- [x] Step1: Add native short/large-text layout and command/drop discovery regressions. Expected: current combined scroller/no empty-folder controls RED.
- [x] Step2: Implement bounded Favorites/Pinned/Today layout and discoverable create/rename/remove/move/drop controls, preserving smooth resize/reveal. Expected: owned layout/input checks PASS at1260x820,960x494,760x400 and text1.0/1.35 (the existing supported maximum; requested1.8 normalizes to1.35) with crowded libraries.
- [x] Step3: Run complete frozen test suite and optimized arm64/x86_64 Info/signature/runtime/min14/exact-entitlement gates; native CUA Cmd-W/folders/pins/scroll/resize checks. Expected: PASS and input hashes match. Commit authorized known changes as a verified checkpoint without marking unfinished extensions complete.
- [x] Step4: Prepare the reviewed local test app/DMG and source push within existing authorization, preserving rollback; no completed-extension publication claim. Record actual native/CI/artifact evidence and remaining full-goal work. No extra review subagent; whole-goal review remains pending at the established final gate.

Verification order adjustment after native discovery: use a focused, verified universal candidate at the existing Visual Four identity to test actual compositor/command transitions before the final long frozen suite. Preserve all rollback material. Candidate builds carry a separate receipt and never satisfy the final distribution gate. The final full suite and both candidate architecture builds must share the same unchanged input manifest before packaging or committing the checkpoint.
