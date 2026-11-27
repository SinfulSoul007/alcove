# Easel Storage Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Preserve profile-scoped editable canvas documents and protected capture bytes for the subsequent native Easel editor.

**Architecture:** Value models live in BrowserCore and merge through the existing profile library. A separate descriptor-based asset store encrypts bytes using the unlocked metadata key; private stores use memory only.

**Tech Stack:** Swift 5.9, Foundation, CryptoKit, Darwin; existing manual Swift check executables.

**Spec:** `docs/superpowers/specs/2026-11-26-easel-storage-design.md`

## Global Constraints

- macOS 14 minimum; Foundation/CryptoKit/Darwin only in BrowserCore. No new dependency, key provider or Keychain behavior.
- Canvas 16384 × 16384; frames finite, contained, width/height 40...4096; 500 items per board.
- Titles 256 UTF-8 bytes; notes 16384 UTF-8 bytes; image dimensions 1...16384, at most 40 million pixels.
- Links absolute HTTP(S), host present, no credentials; no automatic network requests.
- Assets nonempty, at most 32 MiB; directories 0700, files 0600; authenticated profile/asset UUID binding.
- Private mode has no key dependency and performs zero filesystem I/O.
- Storage is not a complete Easel feature and must not be released as one.

## Review Focus

1. Malformed or nonfinite saved geometry must fail safely rather than crash the future renderer — Task 1 decoder checks.
2. Stale editors and invalid multi-item operations must not overwrite newer edits or publish partial mutations — Task 1 edit isolation checks.
3. Duplicate profile-library records must not silently discard unequal boards — Task 1 merge checks.
4. Ciphertext relocation, hardlinks, symlinks and replaced directories must not escape the profile namespace — Task 2 filesystem checks.
5. Private mode and a revoked normal ownership lease must not access protected persisted bytes — Task 2 memory/lease checks.

### Task 1: Canvas documents and profile retention

**Files:** create `Sources/BrowserCore/Easel.swift`, `scripts/EaselCoreChecks.swift`; modify `Sources/BrowserCore/Library.swift`, `Sources/BrowserCore/Profiles.swift`, `scripts/build.sh`.

**Interfaces:** `EaselFrame(x:y:width:height:) throws`; `EaselItem(id:frame:content:) throws`; content cases `.note(text:)`, `.link(title:url:)`, `.image(assetID:pixelWidth:pixelHeight:sourceURL:sourceTitle:)`; `Easel(id:title:createdAt:modifiedAt:revision:items:) throws` (defaults for IDs/dates/items). `Easel.apply(_:expectedRevision:at:) throws`; edits `.insert`, `.replace`, `.remove(Set<UUID>)`, `.reorder([UUID])`, `.rename(String)`. `Easel.merged(_:_:) -> [Easel]`; `BrowserLibrary.easels: [Easel]?`; document format 9.

- [x] Write a backward-compatible JSON fixture test showing that a board in a profile library survives document roundtrip and duplicate-profile repair. Run against baseline. Expected: real assertion failure from lost `easels` content.
- [x] Add the typed model/edit tests before implementation: finite/bounded decode, credentials/scheme rejection, UTF-8 limits, duplicate IDs, exact reorder, stale/invalid atomic rejection, no-op revision stability, unequal/equal library merge and old format retention. Expected: compiler reports missing Easel API until implemented.
- [x] Implement validated Codable values and copy-before-edit behavior; add optional library field/merge and format version. Integrate `ALCOVE_EASEL_CORE_ONLY=1` plus the default build check.
- [x] Run `ALCOVE_EASEL_CORE_ONLY=1 scripts/build.sh`, then the existing core checks against the same rebuilt module. Expected: all pass. Compile all application sources with warnings as errors. Expected: exit 0.
- [x] Commit model, checks and wiring; run task-done with `ALCOVE_EASEL_CORE_ONLY=1 scripts/build.sh`. Expected: green task ledger entry.

### Task 2: Protected capture asset storage

**Files:** create `Sources/BrowserCore/EaselAssetStore.swift`, `scripts/EaselAssetChecks.swift`; modify `scripts/build.sh` to run asset checks alongside Task 1 checks.

**Interfaces:** `EaselAssetStore(root: URL, profileID: UUID, key: SymmetricKey, ownership: MetadataOwnershipLease? = nil) throws`; `EaselAssetStore(privateProfileID: UUID)`; `put(_ data: Data) throws -> UUID`; `read(_ id: UUID) throws -> Data?`; `remove(_ id: UUID) throws`. Root is an existing metadata directory, never created by the store.

- [ ] Write real temporary-directory and private-store checks before implementation. Expected: missing API on first compile. Check roundtrip, ciphertext does not contain owned plaintext marker, 0700/0600 modes, tampering, wrong-key/profile/UUID rejection, size limits, no-follow/hardlink/nonregular/replaced-directory rejection, missing read/remove, unrelated-file retention, lease revocation and private operation without a root/key.
- [ ] Implement immutable UUID ciphertext writes using no-follow directory descriptors, bounded reads and AES-GCM AAD. Private branch stores bytes in memory; do not add a Keychain call or plaintext file fallback.
- [ ] Run `ALCOVE_EASEL_CORE_ONLY=1 scripts/build.sh` and existing core checks. Expected: all pass; no app window is launched. Compile all application sources with warnings as errors. Expected: exit 0.
- [ ] Commit and run task-done with the same focused command. Expected: green task ledger entry. Obtain the required final whole-branch code review, fix consequential findings with RED→GREEN checks, and preserve outstanding editor/capture requirements in the goal acceptance document. Do not merge or publish this subsystem alone.
