# Page process recovery implementation plan

> **For agentic workers:** Use superpowers:executing-plans inline. Steps use checkbox syntax.

**Goal:** Give an unresponsive page its own themed recovery card and a safe Reload control.

**Architecture:** Capture per-page recovery in BrowserStore, render through the existing EdgeToEdgeWebHost overlay lifecycle, and expire actions with document/presentation ownership. Preserve the real page view. Use the actual tab URL as the address-label fallback.

**Tech Stack:** Swift, AppKit, existing theme model, WebKit public delegate APIs.

**Spec:** `docs/superpowers/specs/2026-11-26-page-process-recovery-design.md`

## Global constraints

- macOS14+, both architectures, unchanged six entitlements; VM-only GUI, disposable fixtures, no Keychain/process manipulation.
- No automatic retry and no replacing/reparenting the website to show its error.
- Full browser, extension, visual/performance and release scope remain open until independently verified.

## Review focus

- A background failure must not overwrite another tab's notice or card.
- A queued old Reload must not affect a replacement document, moved page or closed tab.
- Private failures must not request a key or save session data.
- Small split/Quick panes and large text must retain an accessible Reload control through scrolling.
- Existing fullscreen residency and extension/warning overlays must keep their page ownership and ordering.

### Task 1: Page recovery state and native presentation

**Files:** Create `Sources/Browser/WebsiteProcessRecovery.swift`, `Sources/Browser/WebsiteProcessRecoveryUI.swift`, `scripts/WebsiteProcessRecoveryChecks.swift`. Modify BrowserStore document invalidation, termination and transfer; BrowserUI's existing web host; BrowserSidebar's address label. Include the fixture in existing Boost-store checks and retain queued-Boost coverage.

**Interfaces:** `WebsiteProcessRecovery.isCurrent` and `reload()` validate the captured source; `BrowserStore.websiteProcessRecovery(for:)` returns only current recovery; `EdgeToEdgeWebHost.setProcessRecovery(store:webView:)` binds the native card without changing the real web view's frame.

- [x] Write native boundary checks against current behavior: retain an unrelated global notice, show a page-owned card/native Reload, keep the website mounted at full size, clear only the source recovery on retry, and ignore stale controls. Run the baseline in the VM and observe intended failures.
- [x] Implement captured recovery and a native scrollable themed card. Clear it on document invalidation; transfer only a current recovery during a legitimate view transfer. Retain the saved hostname in the sidebar after URL loss.
- [x] Update the existing Boost termination assertions to inspect page-owned recovery. Verify normal/private isolation, navigation/discard/transfer and stale callbacks/buttons with the focused native fixture.
- [ ] Compile full source with warnings as errors, run focused checks GREEN in the VM, inspect installed normal/private card layout at compact/large text widths, then run relevant existing lifecycle/regression checks. No rendered website or whole-browser qualification inferred.
- [ ] Commit/push the verified source and preserve exact CI handles. Record actual source, GUI results, ownership limits and remaining renderer/browser gates.
