# Site Search Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Configured site search through Alcove's existing primary and compact command inputs, with correct account ownership and encrypted settings.

**Architecture:** BrowserCore owns validated SiteSearch/Catalog values and URL construction. BrowserStore owns a cached catalog, durable edits and captured input-context validation. Existing native fields/UI own window-local draft/selection and presentation; WebKit navigation remains in the existing store routes.

**Tech Stack:** Swift, Foundation, AppKit, SwiftUI, WebKit; existing CryptoKit metadata and loopback owned fixtures.

**Spec:** `docs/superpowers/specs/2026-11-08-site-search-design.md`

## Global constraints

- Keep macOS14, metadataformat3, current public0.6.2/build9/tag/assets, six entitlements, no dependencies/private APIs/user data/global input.
- Missing siteSearches uses presets; explicit [] stays empty. Shared encrypted normal configuration, private in-memory changes only; no network before submit.
- Model limits: name80/keyword32 characters/template8192 UTF8 bytes/catalog128; normalized Unicode/case keywords; one `%s` outside HTTP(S) authority, no credentials/whitespace/control in template.
- Query escapes every non-ASCII-unreserved UTF8 byte and cannot change origin; empty/invalid/stale searches write/navigate nothing.
- Preserve command-T new-tab/cancel and native unhandled key behavior; composing IME input is forwarded.
- Inline work on main under standing authorization; per-task commits/ledger, one fresh final reviewer, no per-task agents/reviews or new design questions.

## Review focus

- Ambiguous prefixes, Unicode aliases, query URL delimiters or malformed persisted templates must not redirect or send a different query/site.
- A profile/Space/tab/Peek replacement during editing must not submit a draft to another account or parent page.
- Disabled/deleted/edited shortcuts and failed/locked saves must not silently choose another engine or overwrite live configuration.
- Native marked-text composition/Shift-Tab/unrelated fields keep native handling; compact input remains usable at480pt/text1.35.
- Activating/deactivating search modes/settings must not make network requests, create empty tabs or replace a mounted web view.

### Task 1: Validated site-search model and compatible metadata

**Files:** Create `Sources/BrowserCore/SiteSearch.swift`, `scripts/SiteSearchCoreChecks.swift`; modify `Sources/BrowserCore/Library.swift`, `scripts/build.sh`.

**Interfaces:** Produce public Codable/Equatable/Identifiable/Sendable `SiteSearch(id: UUID = UUID(), name: String, keyword: String, template: String, enabled: Bool = true)`, `validated() throws -> SiteSearch`, `url(for query: String) throws -> URL`, static `defaults: [SiteSearch]`; LocalizedError `SiteSearchError`; `SiteSearchCatalog.init(_ saved: [SiteSearch]?)`, `entries`, `matches(_ input: String)`, `preferredMatch(_ input: String)`, `upserting(_ site: SiteSearch) throws -> [SiteSearch]`, `removing(_ id: UUID) -> [SiteSearch]`. Preferences adds optional siteSearches. Catalog normalizes once, not per query.

- [x] **Step 1:** Write failing core checks for exact Unicode/query-byte round trip and fixed origin, path/query/fragment templates, all invalid template/credential/authority/control/multiple-placeholder/size cases; name/keyword normalization and bounds, disabled/exact/unique/ambiguous matching, duplicate id/keyword repair, upsert/delete/capacity, nil defaults versus explicit empty, legacy/current encrypted-document Codable round trip retaining format3. Add `site-search-core-test` route and full-suite invocation.
- [x] **Step 2:** Run `scripts/build.sh site-search-core-test`; expected missing SiteSearch/Catalog APIs before product code. Implement the model/schema to the exact spec; run again, expected all checks pass/zero diagnostics.
- [x] **Step 3:** Run existing core/profile-format checks as appropriate through `scripts/build.sh quick-core-test` and the current new route, expected preserved format/routing and green. Commit Task1, then task-done with the focused new route.

### Task 2: Durable catalog and account-owned command routing

**Files:** Create `Sources/Browser/SiteSearchActions.swift`, `scripts/SiteSearchStoreChecks.swift`, `scripts/SiteSearchWebsiteChecks.swift`, `scripts/SiteSearchFixture.py`; modify `BrowserStore.swift`, `BrowserActions.swift`, `BrowserProfiles.swift` only as required, `QuickBrowseActions.swift`, `QuickBrowseUI.swift` state, `QuickBrowseWindowController.swift`, `scripts/build.sh`.

**Interfaces:** Consume Task1 models. Produce `SearchInputContext: Equatable` with primary(space/profile/focused-tab/optional-Peek identity) and quick(page/profile/optional-Peek identity). Store: `siteSearchCatalog`, `canEditSiteSearches`, `saveSiteSearch(_:) throws`, `removeSiteSearch(_:) throws`, `searchInputContext(quickID: UUID? = nil) -> SearchInputContext?`, `matchesSearchInputContext(_:) -> Bool`, `resolveSearchInput(_ input: String, selection: SiteSearch?) throws -> URL`. Store command state `commandSiteSearch: SiteSearch?`, `commandContext: SearchInputContext?`, `commandError: String?`; `activateCommandSiteSearch(_:) -> Bool`, `leaveCommandSiteSearch(restoreKeyword: Bool)`, `dismissCommand()`; navigate consumes the selection/context before dismissing and routes to actual focused/Peek/new tab. Quick state gets `siteSearch: SiteSearch?`, `locationContext: SearchInputContext?`, `requestLocation(currentURL: String, context: SearchInputContext? = nil)`, `beginLocation(context: SearchInputContext?)`, `activateSiteSearch(_ site: SiteSearch, context: SearchInputContext) -> Bool`, `leaveSiteSearch(restoreKeyword: Bool)`; existing cancelLocation/showFind reset selection/context. Production editing paths capture scope and validate before existing foreground navigation.

- [ ] **Step 1:** Write failing owned-store checks: encrypted normal edits/relaunch, explicit empty, cache changes only on preferences, duplicates/disabled/delete, locked/failure rollback, private no normal keys/files, pending-operation/shutdown guard. Pin primary/split/Peek/Command-T routes and stale Space/profile/tab/Peek contexts; compact ownership differs from active primary profile, stale/edited provider rejects without fallback; empty selection/submit creates no tab/request and preserves query. Compile new `site-search-store-test`; expected missing store/context APIs.
- [ ] **Step 2:** Implement atomic-before-publish normal preferences using existing document commits, ephemeral private preferences and cache invalidation. Add captured context and selection lifecycle to primary/compact editing. Preserve old direct URL navigation semantics while correcting actual visible Peek routing; clear changed primary contexts. Run store route, expected green/zero diagnostics.
- [ ] **Step 3:** Add loopback fixture and real WebKit checks before backend changes if any: exact query with Unicode/delimiters and selected template, no request before submit, correct primary/split/Peek/compact profile cookies and private separation, stale context/provider rejection. Build script launches/cleans only its owned server/root; add `site-search-website-test` and full-suite invocation. Run focused store/website and existing `quick-window-test`, expected green and no normal user data. Commit Task2; task-done focused store route.

### Task 3: Native input integration and site-search settings

**Files:** Create `Sources/Browser/SiteSearchUI.swift`, `scripts/SiteSearchInputChecks.swift`; modify `FocusedInput.swift`, `QuickBrowseUI.swift` (make QuickBrowseInput internal for owned tests), `BrowserUI.swift`, `LibraryUI.swift`, `BrowserStore.swift` panel case, `CommandActions.swift`, `BrowserAppDelegate.swift`, `Sources/BrowserCore/BrowserCommand.swift`, `scripts/build.sh`, README and goal verification/acceptance docs.

**Interfaces:** Add native input `onTab: () -> Bool = { false }` and `onEmptyDelete: () -> Bool = { false }`, with marked-text forwarding before all browser key actions. Add BrowserCommand.siteSearch (title `Site Search Settings`), BrowserPanel.siteSearch, app action siteSearchSettings using primaryForActive, Settings entry and dedicated SiteSearchPanel(store:availableHeight:). Existing command results show candidate/selected modes; compact address hint/pill use window state and bounded layout.

- [ ] **Step 1:** Write failing native owned-delegate checks for exact/unique Tab activation, ambiguous/unrelated/Shift-Tab forwarding, empty Backspace exit, marked-text Enter/Escape/arrows/Tab/delete forwarding and selection reset. Check actual menu/command/panel entry and mounted-web identity across modes. Add `site-search-input-test`/full-suite route. Expected missing callbacks/actions/panel or current composing-key failures before implementation.
- [ ] **Step 2:** Implement input callbacks and IME handling, primary results/pill/inline errors and compact hint/pill/query widths. Add settings CRUD/preset-prefill UI with explicit normal/private scope, inline validation and paused-save guards. Run input/store/website checks and existing chrome/quick/native suites; expected green/no diagnostics. Render owned hidden hosts at480/760pt/text1.35 and settings short-height; inspect/control geometry, without claiming live keyboard/animation/VoiceOver.
- [ ] **Step 3:** Run `scripts/build.sh test`, optimized arm64/x86_64 builds into separate site-search bundles and exact signature/Info/six-entitlement verification. Expected all checks pass/zero compiler diagnostics; no existing live/review app overwritten. Record count/evidence and source-only status in docs, preserve public0.6.2. Commit Task3; task-done focused input route.

After all tasks, run one fresh whole-branch review under executing-plans. Re-grade by user effect; one RED→GREEN fix pass for Important/Critical findings and green full suite/build gates afterward, no second review. Preserve every ruling/deferred minor and all full-goal gates in the final report before archiving/removing only this plan workspace; push under standing authorization. Automatic discovery/activation prompts and Air Traffic Control remain tracked future scope, not falsely completed.
