# Native Extension Idle Callback Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans for this task.

**Goal:** Let Alcove pages and approved extensions use WebKit's real idle scheduler, including content-script worlds.

**Architecture:** Guard the native feature-catalog/setter lookup and enable only RequestIdleCallbackEnabled on Alcove-owned page and extension preferences before view/context creation. Exercise a real approved MV2 package installed through BrowserStore, including an actual content script.

**Tech Stack:** Swift, WebKit, Objective-C runtime, native VM fixtures.

**Spec:** `docs/superpowers/specs/2026-11-18-extension-idle-callback.md`

## Global Constraints

- macOS 14 browser floor, native extensions require 15.4.
- No JavaScript shim, package patching, process-global feature toggle, or changes to saved approvals.
- Missing feature SPI keeps the current native baseline; full uBO support remains gated.

## Review Focus

- Ordinary callbacks and explicit timeouts must both run in a real hidden background.
- Cancellation must prevent a callback, including after its deadline.
- Real options/interface views must receive the configuration.
- Normal/private pages must have the API even without extensions, while raw unconfigured WebKit retains its baseline.
- Reloaded extensions must run a fresh background rather than reuse stored results.

### Task 1: Configure and qualify native scheduling

**Files:** create `Sources/Browser/BrowserWebPreferences.swift` and `scripts/ExtensionIdleChecks.swift`; modify `Sources/Browser/ExtensionRuntime.swift`, `BrowserExtensionHosting.swift`, `ExtensionMarketplaceView.swift` and `scripts/build.sh`.

**Interfaces:** `BrowserWebPreferences.enableIdleCallbacks(in:WKPreferences)`; `extension-idle-test` target.

- [x] Add actual app-package background/options checks for native functions, ordinary callback/timeout/cancel behavior, real approved content-script callbacks, regular/private API availability, private storage isolation, unchanged raw WebKit defaults, and fresh reload counter.
- [x] Run VM `extension-idle-test`; observe missing API failures on current app configuration.
- [x] Add guarded native feature setup on Alcove-owned preferences before context/view creation. Place ordinary/private/Quick/Peek setup before the shared configureExtensions guard so direct replacement factories are covered.
- [x] Run idle, runtime, action and private checks; expect no failures.
- [x] Review source and address material findings with regressions.
- Commit and push this tested branch for full CI; a full-uBO claim remains gated by the changed engine and actual filtering proof.
