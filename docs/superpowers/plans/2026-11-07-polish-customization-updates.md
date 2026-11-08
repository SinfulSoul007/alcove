# Sidebar, customization, welcome and updates implementation plan

> Execute inline with one independent update subsystem delegated under dispatching-parallel-agents. Keep the full acceptance ledger active; this increment does not redefine goal completion.

**Goal:** Fix sidebar interaction defects, add substantial customization and a first-run setup, and establish update checking/release automation.
**Architecture:** Keep system WebKit and native AppKit/SwiftUI. Appearance state is Codable in encrypted preferences/Spaces; transient interaction state stays in memory. Keep a single sidebar/web-content subtree mounted during visibility transitions. Updates are an isolated, testable GitHub-release client and controller; unsigned installers are never silently executed.
**Spec:** docs/goal/acceptance.md

## Constraints
- macOS 14+, existing session migration, no private-window browsing persistence.
- No additional approval gate: user explicitly instructed continuous building and has already selected native Mac/WebKit.
- Respect Reduce Motion and avoid replaying onboarding on upgrades/private windows.
- No false automatic-update security claim; check and offer the correct release through an allowlisted URL.

## Tasks
- [x] Behavioral tests for appearance decoding/validation, responsive metrics, first-run migration and update selection.
- [x] Codable appearance, custom Space palette/icon and onboarding/update preferences with old-data defaults.
- [x] Stable sidebar/web layout, in-memory drag width with a single persisted commit, native resize cursor and delayed edge reveal.
- [x] Customization editor with presets, custom gradients/accent, density/text/radius/Favorites/icon/motion controls and live preview.
- [x] Animated native welcome/setup, skip/replay, reduced motion, first-install vs upgrade behavior.
- [x] Integrate update controller/menu/settings and normal-window daily cadence after setup; add CI/release workflows.
- [ ] Run full core/store/update checks, build, inspect native UI across themes and sizes, review source, and fix important findings.
- [ ] Commit verified work and publish an honestly labeled update when packaging/runtime checks support it.

## Review focus
First-run migration must preserve existing tabs; private windows never write browsing metadata; style changes must not detach live WKWebViews; hover transitions must not flicker; resize events must not write preferences every pixel; custom colors/dimensions must be bounded; automatic update requests must be disclosed and avoid private-window startup; release selection must reject drafts/downgrades/malicious URLs.

## Evidence and remaining checks

153 behavioral checks pass and the universal ZIP/DMG structural verification passes. Important source-review findings were fixed, including a reproduced legacy-unlock failure and transactional retry behavior. Native 0.4 visual checks remain pending because the new test app lacks Computer Use approval and the older review identity routes input to a stale app path. Do not mark the full visual or Arc-parity objective complete from this increment.
