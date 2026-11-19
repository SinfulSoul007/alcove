# Informational Sheet Quit Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans for this single task.

**Goal:** Make ordinary Quit work while informational browser panels are open.

**Architecture:** A native view bridge leases the public sheet termination policy; only the BrowserUI sheet content installs it. Original window state is restored when its last owner detaches, and blocking owners win during overlap.

**Tech Stack:** SwiftUI, AppKit, native owned fixtures, macOS VM.

**Spec:** `docs/superpowers/specs/2026-11-18-informational-sheet-quit-design.md`

## Global Constraints

- macOS 14 floor; public AppKit API; no private API or global window policy.
- Keep Boosts drafts, nested native confirmations and the pending-output quit choices protected.
- No version bump or overwriting a public installer. All native fixtures use owned temporary/private state and clean up windows.

## Review Focus

- A sheet may acquire its parent after its bridge attaches.
- Reused sheet hosts must change the policy when the panel changes.
- A late dismantle/callback must not override a newer owner or reattach a dead bridge.
- A nested native confirmation and its parent browser window retain their own policy.
- A pending accepted write must still use the existing Wait/Cancel/Quit termination path.

### Task 1: Scoped informational sheet termination

**Files:** create `Sources/Browser/BrowserSheetQuitPolicy.swift`, `scripts/BrowserSheetQuitChecks.swift`; modify `Sources/Browser/BrowserUI.swift` and `scripts/build.sh`.

**Interfaces:** `BrowserSheetQuitPolicy(preventsTermination: Bool)` as a sheet-local `NSViewRepresentable`; a main-actor Host manages an original-value lease per native sheet. BrowserPanel policy allows clean informational panels; child editors in LinkRoutingUI, SiteSearchUI and AppearancePanel protect their actual unsaved draft. Boosts stays protected; spaces is not a sheet.

- [ ] Add actual BrowserUI Library/Settings sheet regression checks. Call actual AppDelegate.quit with a cancelling NSApplication delegate; expect the delegate to be consulted and the sheet to remain open.
- [ ] Run native fixture before implementation; expect actual default policy to block these consultations. Compile/type errors do not count as RED.
- [ ] Implement sheet-only bridge with late-attachment observation, input transparency, original-state restoration and overlapping-owner protection. Apply to BrowserUI sheet root, preserving Boosts blocking.
- [ ] Extend native checks for all panel policies, nested confirmation, panel change, reparent/detach, overlapping owners and dismantled deferred callbacks.
- [ ] Run `bash scripts/build.sh browser-sheet-quit-test`, `bash scripts/build.sh page-output-lifetime-test`, `bash scripts/build.sh chrome-test`; expect zero failures. Run complete hosted CI on the exact final source.
- [ ] One fresh whole-branch review, one material-finding fix pass, fresh verification, commit and push. Native positive and full CI are gates before release integration.
