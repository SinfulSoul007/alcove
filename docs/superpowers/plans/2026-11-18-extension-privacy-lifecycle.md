# Extension Privacy Lifecycle Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Preserve extension installation priority and settings through ordinary lifecycle changes without stale authorization.

**Architecture:** Add optional encrypted installation metadata and deterministic legacy repair. Unload successfully before removing host registration; revoke grants only when unload fails. Exercise the actual native controller and retained extension page.

**Tech Stack:** Swift, BrowserCore Codable metadata, AppKit, WKWebExtensionController, Terminal Mac.

**Spec:** `docs/superpowers/specs/2026-11-18-extension-privacy-lifecycle.md`

## Global Constraints

- Browser macOS 14 floor; native extensions require macOS 15.4.
- Public compatibility gates remain in place; changed native engine is pending.
- Use only owned temporary browser profiles and fixtures in the dedicated VM.
- Keep encrypted metadata format 8 compatible via an optional field.

## Review Focus

- Disabled legacy extensions retain their relative installation order after re-enable.
- Duplicate catalog mirrors cannot increase priority or revoke an otherwise identical approval.
- Clock changes must not make a genuinely newer install lose priority.
- A retained unloaded native extension page cannot perform privileged storage operations.
- A failed native unload leaves no permissions active and remains retryable.

### Task 1: Persist installation priority

**Files:** `Sources/BrowserCore/BrowserExtension.swift`, `Sources/BrowserCore/ExtensionCatalog.swift`, `Sources/Browser/ExtensionActions.swift`, `Sources/Browser/ExtensionRuntime.swift`, `scripts/ExtensionCoreChecks.swift`, `scripts/ExtensionStoreChecks.swift`.

**Interfaces:** `BrowserExtensionRecord.installedAt: Date?`, `validInstallationDate: Date?`; native `_setPrivacyInstallationDate:` selector when supported.

- [x] Add checks for legacy catalog date migration, deterministic ordered dates, malformed date recovery, duplicate earliest-date precedence, and idempotent encrypted round-trip.
- [x] Run `bash scripts/build.sh extension-core-test`; expect new date assertions to fail.
- [x] Add store checks for actual first-install dates, disabled installs, update and enable preservation, and later install priority.
- [x] Run store checks in VM; expect missing date assertions to fail.
- [x] Add optional date field, bounded finite date validation, deterministic older legacy dates, and duplicate earliest valid date merge. Assign monotonic dates on new approval, preserve previous date on update. Send native date before load only when supported.
- [x] Run core and VM store checks; expect zero failures. Commit the task.

### Task 2: Preserve settings on unload with stale-context denial

**Files:** `Sources/Browser/ExtensionRuntime.swift`, `Sources/Browser/ExtensionAdapters.swift`, `scripts/ExtensionRuntimeChecks.swift`.

**Interfaces:** `NativeExtensionProfile.unload(approvedRecords:[BrowserExtensionRecord]? = nil) throws`; `authorized(_:profileID:client:) -> Bool` additionally requires `isLoaded`.

- [x] Add native retained options-page storage checks before/after successful unload and re-enable. Assert unload preserves grant metadata, removes controller/host registration, rejects stale host callbacks and cannot write a storage marker after unloading.
- [x] Run VM runtime test; expect the preserved-grants assertion to fail while stale access remains denied.
- [x] Unload first, remove context only on success; on failure clear grants/private approval and retain context. Add loaded-state authorization gate.
- [x] Reproduce explicit approval removal separately; intersect native grants with validated current catalog approvals at each production unload path, preserving saved grants on disable and ending temporary-only rights at shutdown.
- [x] Run runtime, permission, adapter, private, core and store checks in VM; expect zero failures. Review actual source unload failure paths before committing.

### Final verification

- [x] Request fresh source review of this branch, including all five Review Focus conditions.
- [x] Address material review findings with failing regression checks, then run affected checks.
- [ ] Push branch for full CI. Keep engine-positive qualification pending until the changed framework exists.
