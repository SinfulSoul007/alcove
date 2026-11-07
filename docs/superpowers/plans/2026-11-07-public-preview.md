# Alcove Public Preview Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Produce an installable unsigned preview with tested local privacy controls and everyday browser tools.
**Architecture:** Native AppKit/SwiftUI windows with window-local BrowserStore instances, system WKWebView, encrypted metadata via CryptoKit and Keychain. Release scripts generate downloadable preview artifacts from the verified app.
**Tech Stack:** Swift, WebKit, CryptoKit, Security, GitHub Releases.
**Spec:** docs/superpowers/specs/2026-11-07-public-preview-design.md

## Global Constraints
- macOS 14+, no package dependencies, preserve existing sessions through migration.
- Unsigned preview only; no notarization or complete-security claim.
- Private-window metadata never reaches persistent files.
- Existing Spaces share a profile; memory eviction becomes opt-in.

## Review Focus
- Private-window redirects, downloads and closed-tab state must not leak into saved metadata.
- Lost Keychain keys or corrupted ciphertext must not cause an empty session to overwrite user data.
- Browser origin labels must reflect committed WebKit navigation rather than a typed URL.
- Closing a split tab or switching windows must route commands to the correct live view.
- A release ZIP/DMG must contain executable app resources and accurate architecture/signature labels.

### Task 1: Metadata and privacy model
- [x] Add behavioral failing tests for folder/closed-tab/archive behavior, encrypted storage, tampering, file modes and private persistence.
- [x] Implement model migration/defaults and AES-GCM storage with injected keys for tests; Keychain provider in app.
- [x] Run core suite and encrypted-store checks.

### Task 2: Browser controls and windows
- [x] Integrate encrypted sessions and library; never flush private stores; fail closed on unreadable stored metadata.
- [x] Add private windows, find, zoom, bookmarks/history/download UI, file uploads, camera/mic prompts and accurate origin display.
- [x] Add folders, restore closed tabs and opt-in archive; make lossy memory eviction opt-in.
- [x] Build and exercise native flows, including private writes and split closure.

### Task 3: Distribution
- [x] Rename app to Alcove, add minimal sandbox and hardened runtime, build ZIP/DMG with checksums and explicit unsigned labels.
- [x] Verify app signature/entitlements and package contents; document installation and security limitations.
- [x] Review changes, fix important findings, rerun checks; commit/push and publish an explicitly unsigned prerelease download.

## Execution notes
- Final review found archive truncation and an older cross-Space popup close bug. Both were reproduced by failing StoreChecks, fixed, and verified in the full suite.
- Ruling: unsigned archives are previews, not stable releases; native sandbox launch works on the development Apple Silicon Mac. Intel compilation and minimum OS targeting do not substitute for hardware/OS testing.
- Ruling: legacy unsandboxed JSON import is explicit via NSOpenPanel to preserve the sandbox boundary; the original file is not silently deleted.
- Packaging verified: both architecture slices compiled; universal code signature, executable modes, bundle resources and ZIP checksum pass. DMG creation cannot access image devices here, so the downloadable deliverable is ZIP. 37 behavioral checks pass. Publication follows source commit.

- Working in the user-selected existing browser directory; no worktree created because placement was explicit.
- No signing identities are installed. User confirmed no Apple Developer membership, and requested a downloadable version without it.
