# WebKit Extensions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans inline, honoring existing autonomous main-checkout/push/preview consent. No per-task implementer/reviewer agents or repeated design/mode gate.

**Goal:** Add real WebKit extension installation, account-safe hosting, permission review and native browser controls without shrinking the full browser goal.

**Architecture:** Bounded immutable package preparation and encrypted per-profile catalogs feed an availability-guarded native host. Profile controllers attach before web-view creation; actual tab/window adapters and revocable permission tickets bridge engine requests into existing durable store/window-owner operations.

**Tech Stack:** Swift, Foundation/Darwin, CryptoKit/Security, system zlib, AppKit/SwiftUI, public WKWebExtension on macOS15.4+.

**Spec:** `docs/superpowers/specs/2026-11-11-web-extensions-design.md`

## Global Constraints
- Browser minimum macOS14; host API guarded at15.4; no private APIs/new dependencies/JIT entitlement. Keep exact existing six entitlements and unchanged Keychain policy.
- Metadata5 migrates1–4, rejects6+;0.9.0/build16/candidate`v0.9.0-preview.1`; stable Visual Four identity.
- Import limits:128MiB input,256MiB expanded total,64MiB/file,10,000 entries,1MiB manifest,16MiB CRX header,64 proofs. No shell extraction of untrusted archives.
- No execution of downloaded third-party extensions in tests without required specific authorization; own generated/signed fixtures only. Never read Arc profile files.
- Private default: no normal keys/metadata writes. Private extension access requires explicit approval, separate temporary website/UCC state and transient private grants.
- Keep0.8 tagf1b3445 immutable. Its published release passed pinned-tag verification; do not treat newer main Info.plist as its source.
- Build/test shared caches sequentially, with process-scoped `caffeinate -is`; no source/test edits during complete gates. Remote exact-source CI may run independently under a ledger ruling.
- Reuse verified1,625-check baseline at63d651c/f1b3445 before the first RED, rather than rerunning it before implementation.
- ONE fresh gpt-6-astra/high/fork-none whole-plan final reviewer, no reviewer subagents; ONE author RED→GREEN fix pass plus final full/build gates, no re-review. Full browser goal remains active.

## Review Focus
- Crafted folder/ZIP/CRX names, headers, sizes, proofs and live filesystem replacement must not escape roots, follow links, allocate unbounded data, grant a forged identity or damage a prior install.
- Permission/update/remove replies after code/profile/window changes must not revive revoked grants, leak private URLs into saved metadata or switch an extension into another account.
- Main/split/Quick/Peek/popups, live handoffs and closed-main/private-only ownership must expose the actual page/controller, complete navigation decisions once and preserve forms unless reload was explicitly accepted.
- macOS14, Keychain-pending startup, missing assets and failed profile clearing must remain responsive, honest and recoverable without silently loading a persistent store or bypassing expected extensions.
- Short/large-text managers, action popovers, commands/context items and Web Store network failures must remain usable without unsupported APIs masquerading as compatible behavior.

### Task 1: Package verification, catalog and durable installation foundation

**Files:** new `Sources/BrowserCore/BrowserExtension.swift`, `ExtensionManifest.swift`, `ExtensionZIP.swift`, `ExtensionCRX.swift`, `ExtensionPackage.swift`; modify Library/Profiles; new `Sources/Browser/ExtensionActions.swift`; new `scripts/ExtensionCoreChecks.swift`, `ExtensionStoreChecks.swift`, `ExtensionFixtures.swift`; build.sh, Info.plist and explicit current/future format assertions.

**Interfaces:**
- `ExtensionGrantSet: Codable, Equatable`: approved API strings, host-pattern strings, matching package digest; private access defaults false. Runtime-only transient grants are not Codable fields.
- `BrowserExtensionRecord: Codable, Identifiable, Equatable`: UUID, manifest name/version/description/version number, package digest, source kind/store ID/signer identity, requested/optional API/hosts, grant set, enabled and pending-removal state. Paths derive from UUID/digest; no imported absolute path is saved.
- `BrowserProfile.extensionControllerID: UUID?`, repaired/saved before native persistent use; `BrowserLibrary.extensions: [BrowserExtensionRecord]?`. Reassigned/duplicate ownership identities revoke approvals and storage identity instead of inheriting another account.
- `ExtensionPackage.prepare(at:URL, stagingRoot:URL, expectedStoreID:String? = nil, requireStoreProof:Bool = false) throws -> PreparedExtensionPackage`; prepared manifest, digest, verified identity and owned staging URL. No code execution.
- `ExtensionPackage.publish(_:profileID:extensionID:packagesRoot:) throws -> InstalledExtensionPackage`; only immutable controlled destination; report whether this invocation created it so a failed metadata save cannot remove another install.
- `BrowserStore.installExtension(_:replacing:approval:) async throws -> UUID`, `setExtensionEnabled(_:profileID:enabled:)`, `setExtensionGrants(_:profileID:grants:)`, `beginRemoveExtension(_:profileID:)` use persist-before-publish and revalidate code/profile/pending operations. Native loading remains Task2.

- [x] Step1: Write raw encrypted schema/format migration regressions first and run the focused extension-core mode. Expected: current model drops extension/controller data or remains format4; plaintext/future-version controls still pass. Add typed package/catalog fixtures before implementing their interfaces; missing new interfaces are an expected RED, not a passing gate.
- [x] Step2: Implement model/repair and manifest decoding for MV2/MV3, localized names/default locale, API vs site patterns, entry-resource paths, action/options/background/incognito declarations. Validate types/bounds and retain unsupported capabilities for review, without granting them. Add malformed/localized/owner-collision/repeated-merge cases. Expected: schema/model checks PASS, no diagnostics.
- [x] Step3: Add package regressions for stored/deflated/Unicode ZIPs, descriptors, CRC/size/header mismatch, duplicate normalized paths, links/traversal/overlap, declared-vs-actual limits, source-folder retarget/link races and cancel cleanup. Implement bounded deterministic extraction/copy with system zlib and owned root descriptors. Expected: valid resources preserved and unsafe packages fail without outside writes or unbounded allocation.
- [x] Step4: Generate independent ephemeral RSA/ECDSA CRX3 fixtures. Pin the current official verifier behavior and production publisher-key hash in a reference note. Test valid identity/proofs, expected-ID/publisher mismatch, tampered signed header/archive/proof, duplicate/malformed protobuf/SPKI/lengths and unsigned-source labeling. Expected RED before verification, then PASS; no Keychain material or vendor extension code used.
- [x] Step5: Add owned-store encrypted install/update/grant/remove/failure/private/missing-profile regressions; implement transactions and owned orphan/staging cleanup. Changed code clears approval; failed save keeps old catalog/ciphertext/live pages. Update only current/future format assertions to5/6, retaining explicit legacy4 fixtures. Set0.9.0/build16. Run focused extension core/store checks sequentially. Expected: PASS, zero diagnostics.
- [x] Step6: Run task-done through the verified-commit wrapper, which executes `caffeinate -is scripts/build.sh test`, verifies frozen inputs and commits only after success. Expected: complete suite PASS, zero diagnostics, source frozen during gate. Record every ruling/cost.

### Task 2: Account-safe native engine and actual browser adapters

**Files:** new Browser `BrowserExtensionHosting.swift`, `ExtensionRuntime.swift`, `ExtensionTabs.swift`, `ExtensionWindows.swift`, `ExtensionPermissions.swift`, `ExtensionNavigation.swift`; BrowserStore/Profiles/MetadataLoading/AppDelegate/WindowOwner/QuickBrowseStore/PeekPanel; owned runtime/website/lifetime fixtures and build modes.

**Interfaces:** non-availability-specific `BrowserExtensionHosting` protocol stores in BrowserStore; `@available(macOS15.4,*)` native implementation owns profile controllers, immutable package/context revisions and transient grants. `configure(_:profileID:)` attaches before WKWebView creation; a once-completing navigation-policy ticket bounds preparation and cancels stale requests. `refresh`, `shutdown`, profile suspend/data removal and popup/command requests share one owner lifecycle. Actual native window/tab adapters reference store UUIDs and weak WKWebViews, never synthetic duplicate websites.

- [x] Step1: Write real owned-WebKit MV2/MV3 tests for no pre-grant injection, approved code/host behavior, optional/expired/denied grants, storage/account separation, private default and explicit permission, startup gate and tampered assets. Expected: extension behavior missing/RED without touching real profiles.
- [x] Step2: Implement availability boundary, explicit data-store/controller IDs and load preparation. Wire main/split/Favorites/Quick/Peek/popup configurations before creation. Bound/complete navigation tickets once; add close/reopen/timeout/retry/newer-navigation regressions. Expected: no unexpected persistent access during locked/private startup, no deadlocks or lost forms.
- [x] Step3: Implement actual window/tab metadata/actions/notifications, extension origins, options and action popup/commands/context items. Test cross-profile denial, same-profile identity-preserving handoff, paused/missing profiles, tab creation/selection/close, split/Peek and closed-main/private-only lifetimes. Unsupported privileged APIs stay explicitly unavailable. Expected: real fixture extension sees and changes only its own current account/pages.
- [x] Step4: Implement explicit private access with separate website/UCC data, auxiliary normal-owner leases, transient private permission replies and Reopen With Extensions consent after locked startup. Test new/revoked grants after window/code/profile changes, private closure, normal closure/reopen, last-window release and no serialized private URL/grant. Integrate durable profile clear/delete/uninstall data removal/retry. Expected: no stale privilege/data recreation or cookie transfer.
- [x] Step5: Run focused runtime/website/lifetime/startup/profile checks, then commit and task-done with the complete test command. Expected: whole suite PASS, zero diagnostics; no source edits during gate.

### Task 3: Native installation, permission controls and release

**Files:** new Browser `ExtensionsPanel.swift`, `ExtensionRequests.swift`, `ExtensionPrompts.swift`, `ExtensionStoreDownload.swift`, `ExtensionActionButton.swift`; Browser UI/settings/commands/AppDelegate/Quick menus; owned native/input/network/layout checks; README/SECURITY/RELEASE/goal evidence.

**Interfaces:** `ExtensionInstallPreview` captures profile/store lifetime, candidate digest and requested privileges. Approval revalidates all of them before committing/enabling. `ExtensionStoreDownload.fetch(id:transport:) async throws -> PreparedExtensionPackage` uses ephemeral credential-free bounded HTTPS transfers, Google's published stable package-selection version and official update/CDN allowlist; requires expected ID and publisher proof. Manager and action controls call the same Store/runtime transactions, with macOS14 unavailable state.

- [ ] Step1: Add native presenter/editor/input and owned transport tests for folder/archive/store-ID preview, no execution before approval, source/profile/code drift, failed/cancelled update, grants/private access/removal retries, redirect/size/status/cookie rules and keyboard cancellation. Expected: RED before UI/network implementation.
- [ ] Step2: Implement install/update/details/permissions/native popovers and manager access from menu/settings/command/sidebar/Quick; accessible labels, source/profile identity and scrollable short/large-text layouts. Fetch action/context state at opening. Add actual popup/content/form lifetime and navigation tests; do not certify untested vendor compatibility. Expected: PASS with no automatic privilege grants or unsupported fallback claims.
- [ ] Step3: Finish owned end-to-end store/package/engine/UI cases; run full frozen suite and both optimized architecture/Info/signature/runtime/min14/exact-six-entitlement gates. Expected: PASS, zero diagnostics. Keep baseline0.8 release observation/verification separate from newer source.
- [ ] Step4: Commit; task-done; ONE fresh gpt-6-astra/high whole-plan review with Review Focus verbatim and all ledger rulings. Regrade findings/declined judgments, ONE author RED→GREEN fix pass and final whole suite/builds; no second review. Expected: no unresolved Critical/Important findings.
- [ ] Step5: Push authorized source; inspect exact-source CI to terminal, verify downloaded universal DMG/ZIP/digests and pinned source. Update Visual Four only after CUA-confirmed quit at the same path/identity; exercise owned install/permissions/popup/private/profile/removal/relaunch and broad native UI. Publish the unsigned preview through the matching tag workflow, download public assets back and verify them; update the README/receipt/report, enumerate all rulings/costs and remaining full-goal gaps, archive only this plan workspace. Never mark the full browser goal complete for this increment.
