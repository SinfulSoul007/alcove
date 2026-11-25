# Reader Mode Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking. User explicitly chose autonomous inline execution; no subagents or routine approval questions.

**Goal:** Add safe, reversible native Reader mode to each focused webpage context.
**Architecture:** Clone-and-extract in an isolated world; allowlist serialization; separate inert Reader overlay; identity-bound per-document lifecycle.
**Tech Stack:** SwiftUI, AppKit, WebKit, vendored Mozilla Readability 0.6.0 (Apache-2.0).
**Spec:** docs/superpowers/specs/2026-11-24-reader-mode-design.md

## Global Constraints

macOS 14+; local text processing only; source document/form/scroll preservation; no privileged renderer; no release/version/engine changes; no push/merge/tag/publish; only owned native fixtures.

## Review Focus

- Malicious article markup, URL schemes and embedded resources remain inert.
- A stale extraction cannot appear after navigation, close, transfer or clearing.
- Split focus, Peek and Quick target the source actually displayed in their own window.
- Reading controls preserve position; source drafts and scroll survive exit.
- Missing resources and unsupported pages provide honest feedback.

### Task 1: Extraction and resources

Files: Sources/Browser/ReaderAssets/*, Sources/Browser/ReaderResources.swift, scripts/ReaderExtractionChecks.swift.
- [x] Write native behavioral fixture for article structure, chrome removal and original DOM/form preservation; run RED without extractor.
- [x] Vendor immutable licensed Readability source and implement bounded allowlist serializer.
- [ ] Run GREEN plus hostile markup, links, short pages and size limits.

### Task 2: Presentation and lifecycle

Files: Sources/Browser/ReaderMode.swift, Sources/Browser/ReaderOverlay.swift, BrowserStore.swift, BrowserUI.swift, scripts/ReaderModeChecks.swift.
- [ ] Write checks for source ownership, cancellation, inert rendering and restore; observe RED.
- [x] Implement captured identity sessions, timeout and native overlay controls; hook existing document invalidation and handoff.
- [ ] Run native checks for normal, split, Peek, Quick and stale session behavior.

### Task 3: Discovery and integration

Files: BrowserAppDelegate.swift, BrowserCore/BrowserCommand.swift, CommandActions.swift, QuickBrowseUI.swift, PeekPanel.swift, scripts/build.sh, Package.swift, README.md.
- [x] Expose native View menu/command and webpage controls without a new conflicting shortcut.
- [x] Wire resources into manual app, native fixtures and SwiftPM.
- [ ] Build native app, run relevant core and Reader gates, inspect packaged resources and review diff.
- [ ] Commit local implementation and report actual results and open GUI/full-browser gates.

## Recorded execution status

Implementation and source/headless verification are recorded in docs/reader-mode-verification.md. Native complete GREEN and pixel review remain open because the dedicated console is locked and strict native checks encountered terminated WebContent. No approval round or native assertion weakening was substituted for those gates.
