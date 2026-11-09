# Link Routing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ordered Arc-style URL routes/defaults with account-correct external, archive and Peek destinations and native configuration.

**Architecture:** BrowserCore owns canonical address/rule values and compatible archive/Space hints. BrowserStore resolves ownership and commits complete candidates before view handoff. Native UI presents configuration and scoped reload consent; owned fixtures verify real WebKit behavior.

**Tech Stack:** Swift, Foundation/Darwin, AppKit, SwiftUI, WebKit, CryptoKit; no new dependency.

**Spec:** docs/superpowers/specs/2026-11-09-link-routing-design.md

## Global Constraints

- macOS14, metadataformat3, exactly six existing entitlements, no dependencies/private APIs/global input/user-data fixtures. Immutable public0.6.2/build9/assets; developing source0.6.4/build11/tagv0.6.4-preview.1 only at final integration, no new release/tag.
- Rule limit128; pattern1...2048 UTF8 bytes, trimmed/canonical-composed/no controls. Host input4096 UTF8 bytes; DNS253/label63. Contains/Equals matching and URI normalization exactly as the spec.
- First enabled match; missing destination blocks without fallback. Named Spaces choose profile; Quick/Recent retain chosen/source profile. Private ignores normal routing; save before publish; preserve view/form/history on same-profile handoff.
- Rules apply to external dispatch, normal/Space archive restoration and Peek opening; explicit compact/archive/manual destinations override. Archive origin and per-profile last Space are optional compatible metadata.
- Preserve unrelated live primary Peek as a same-profile tab in the same durable candidate before a Space opening; reload consent snapshots revalidate lifetime/document/URL/rule/source/target/window.
- Inline/main under standing preference; focused TDD/per-task commits and ledger; final whole suite/builds and ONE fresh whole-branch reviewer, no per-task agents/reviews/design questions.

## Review Focus

- URL aliases, Unicode, credentials/query substrings or malformed hosts must not accidentally select another account; matching must be deterministic and explicit.
- A matching deleted/reassigned/paused target or edited rule during consent must not fall through or apply old consent to a new owner/document.
- Failed metadata writes must leave archive records, selected Space, compact records and original preview/form/view ownership intact.
- Preserving one Peek and moving another must not duplicate/reparent the wrong native view, share cookies or consume a private/foreign profile.
- Busy/closed source windows, double/late confirmations and native edited-field/default interactions must not create extra windows or undo newer settings.

### Task 1: Canonical rules and compatible Space/archive metadata

**Files:** Create Sources/BrowserCore/LinkRouting.swift and scripts/LinkRoutingCoreChecks.swift; modify QuickBrowse.swift, Library.swift, Session.swift, Profiles.swift and scripts/build.sh.

**Interfaces:** Public RoutingHost.normalized(_ raw:String)->String?; LinkRuleKind:String/Codable/Sendable contains/equals; LinkDestination:Codable/Equatable/Hashable/Sendable quickBrowse/mostRecentSpace/space(UUID); LinkRule:Codable/Equatable/Identifiable/Sendable(id:UUID=UUID(),kind:LinkRuleKind=.contains,pattern:String,destination:LinkDestination=.mostRecentSpace,enabled:Bool=true), validated()throws->LinkRule; LinkRuleError:LocalizedError. LinkRuleCatalog.init(_ saved:[LinkRule]?), entries:[LinkRule], matching(_ url:URL)->LinkRule?, upserting(_:)throws->[LinkRule], removing(_ id:UUID)->[LinkRule], moving(_ id:UUID,to:Int)throws->[LinkRule]. Preferences.linkRules:[LinkRule]?, linkDefaultDestination:LinkDestination?; Tab.archivedSpaceID:UUID?; Session.lastUsedSpaces:[UUID:UUID]?, activateSpace(_ id:UUID)->Bool. QuickBrowseRouting.normalizedHost delegates the shared normalizer; profile repair validates last-used hints.

- [x] **Step 1:** Write failing core checks for exact Contains/Equals representations, schemes/root/non-root slash/query/fragment/case, literal regex text, Unicode/IDN and numeric IPv4/validated compressed IPv6 aliases, credential/path/query host confusion, malformed/oversized host/pattern, disabled/duplicate/order/move/capacity/orphan behavior. Pin nil legacy fields, format3, archive origin and cleared/filtered recent hints, real AES-GCM round trip. Add link-routing-core-test/full-suite route; run it, expected missing APIs before code.
- [x] **Step 2:** Implement the exact models/normalizer and optional metadata. Observe any existing-Quick normalization failures before redirecting it to RoutingHost. Run scripts/build.sh link-routing-core-test, expected all checks pass/zero diagnostics; run scripts/build.sh quick-core-test and site-search-core-test, expected preserved behavior. Commit Task1; task-done with link-routing-core-test.

### Task 2: Durable route resolution and page-safe openings

**Files:** Create Sources/Browser/LinkRoutingActions.swift, LinkOpenings.swift and scripts/LinkRoutingStoreChecks.swift, LinkRoutingWebsiteChecks.swift, LinkRoutingFixture.py; modify BrowserStore.swift, BrowserActions.swift, BrowserProfiles.swift, BrowserProfileRequests.swift activation assignments, QuickBrowseActions.swift, QuickBrowseStore.swift, PeekPanel.swift, scripts/build.sh. Reuse test-only SiteSearchFixtures.swift and OwnedWebsiteStores.swift without touching real data.

**Interfaces:** Store linkRuleCatalog, canEditLinkRules, saveLinkRule(_:)throws, removeLinkRule(_:)throws, moveLinkRule(_:by:Int)throws, setDefaultLinkDestination(_:)throws, effectiveDefaultLinkDestination. ResolvedLinkDestination:Equatable quick(profileID:UUID)/space(spaceID:UUID,profileID:UUID)/newSpace(profileID:UUID); LinkRoutingDecision:Equatable(rule:LinkRule?,destination:ResolvedLinkDestination). linkDecision(for:URL,ownerProfileID:UUID?=nil,preferredSpaceID:UUID?=nil,useExternalDefault:Bool=true,explicitDestination:LinkDestination?=nil)throws->LinkRoutingDecision. PeekPromotionRequest captures context/lifetime/document/URL/source profile/explicit choice/decision; preparePeekPromotion(in:PeekContext,to:UUID?=nil)throws->PeekPromotionRequest, performPeekPromotion(_:allowProfileChange:Bool=false)throws->UUID. Existing promotePeek signature delegates these. Add restoreArchivedRouted(_ id:UUID,profileID:UUID)throws->UUID; keep restoreArchived(_:) wrapper. PreservePrimaryPeek preparation/publication helpers stay internal; PeekState gains initial requestedURL:URL? with optional init argument. Source read and model publication use candidate documents. New test routes link-routing-store-test and link-routing-website-test own their loopback server.

- [x] **Step 1:** Write store REDs for encrypted CRUD/relaunch/default/legacy/private/paused/busy/shutdown/invalid write, rule priority versus remembered account/default, missing target blocked, recent profile Space/archived origin, source-owner archive/explicit compact override and exact rollback. Pin same-profile Peek/Quick handoff identity, unrelated primary preservation, initial nil-URL preview, canceled/cross-profile/stale lifetime/document/rule/target consent and no extra windows. Run new store route, expected missing APIs/current incorrect ownership or destructive transitions.
- [x] **Step 2:** Implement atomic catalog/defaults, last-used activation, resolution and opening candidates; preserve primary Peek before external/archive/other-Peek Space transition. Apply archive rules/origin and explicit overrides. Implement snapshots and handoff/reload guard; no live web view moves before successful save. Run store route, expected green/zero diagnostics.
- [x] **Step 3:** Write real-WebKit loopback tests before any further backend fixes: two random named stores/cookies plus private, external/default/remembered/rule/recent/archive destinations, same-profile form/scroll/history handoff, unrelated Peek preserved, fresh cross-profile view after consent, failed/stale/no-match queries produce no request. Compare RoutingHost to engine new URL parsing without navigating probe addresses. Run new website route plus existing quick-window-test/quick-website-test and site-search-store-test, expected green/zero diagnostics. Commit Task2; task-done store route.

### Task 3: Native Link Preferences and scoped consent

**Files:** Create Sources/Browser/LinkRoutingUI.swift, LinkRoutingRequests.swift, scripts/LinkRoutingInputChecks.swift; modify BrowserCore/BrowserCommand.swift, BrowserStore panel, CommandActions.swift, BrowserUI.swift, LibraryUI.swift, BrowserAppDelegate.swift, QuickBrowseUI.swift, QuickBrowseWindowController.swift, PeekPanel UI, scripts/build.sh, scripts/Info.plist, README and goal verification/acceptance docs.

**Interfaces:** BrowserCommand.linkRouting with title Link Routing Settings and Link Preferences/Air Traffic Control aliases; BrowserPanel.links; native linkRoutingSettings action. LinkRoutingPanel(store:availableHeight:) exposes Contains/Equals, expression, enabled/move/delete, Quick/Recent/Space destination and default, local test-URL preview, private/paused status and draft validation. LinkRoutingPrompt owns injectable confirm(NSWindow,String,String,@escaping(Bool)->Void); .live creates window-bound Cancel/Reload in Profile sheet. requestExpandPeek(in:PeekContext,confirmation:LinkRoutingPrompt?=nil,onComplete:((UUID)->Void)?=nil,onError:((Error)->Void)?=nil) captures/revalidates source window and request; existing expandPeek wrapper and compact callback use it. peekOpenTitle(in:) describes actual choice. A primary lease opens only on Space success; no native modal is shown in tests.

- [x] **Step 1:** Write native owned REDs for actual settings/menu/command entry, rule edit/enable interleaving, default rollback, match preview local/no network, short/large-text layout and stable mounted web. Pin injected confirmation accept/cancel/duplicate/late/source-window-close/rule/profile/document mutation and actual NSAlert construction. Add link-routing-input-test/full-suite; expected missing UI/request APIs before implementation.
- [x] **Step 2:** Implement native panel and shared atomic callbacks, scoped prompt and Peek titles/compact success lease behavior. Render owned hosts at600pt/short height and text1.35; inspect geometry without calling it live focus/animation/VoiceOver success. Run new input route and affected store/website/existing chrome/quick-native, expected all pass/zero diagnostics.
- [x] **Step 3:** Advance developing Info0.6.4/build11/tagv0.6.4-preview.1, update source-only docs/remaining gates. Run scripts/build.sh test, separate optimized arm64/x86_64 build/link-routing bundles and strict exact Info/signature/six-entitlement checks, expected complete green/no diagnostics/no live-review app overwrite. Commit Task3; task-done input route.

After all tasks: fresh whole-branch review from623351b through final HEAD; weigh every Review Focus and ledger Ruling. One RED→GREEN fix pass for re-graded Important/Critical plus full suite/build gates, no second review; preserve all rulings/deferred minors in report/outputs before archiving/removing only this workspace. Push under standing authorization and inspect exact source CI; keep whole browser goal active. Live Arc matching/profile/default semantics and all original visual/data/performance/hardware/install/full-feature gates remain unproven until verified.
