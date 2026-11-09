# Site search and command input

The full browser goal includes Arc's keyboard-driven site search as well as the still-open native/sidebar/animation work. Add configured site search to Alcove's existing command and compact address fields: type a shortcut, Tab into its search mode, then submit a query. The selected site stays visible. This increment does not complete full Arc parity or the blocked live-native QA.

Reference: [Arc's April13,2023 release notes](https://resources.arc.net/hc/en-us/articles/20498377604887-Arc-for-macOS-2023-Release-Notes) document a configured shortcut followed by Tab; September21 records activation across profiles. These ground the keyboard workflow, not a claim that every Arc default or discovery behavior is reproduced.

## Approach

Extend the existing Swift/AppKit/SwiftUI/WebKit inputs and encrypted Preferences. A separate web search page would bypass the native command experience. A remote suggestion service would disclose typing and is unnecessary. The implementer chooses a shared normal-profile configuration and local matching; the user's standing opt-out waives new design/approval questions. Private owners start with built-in presets and keep their own changes in memory. Browsing always uses the chosen window's actual profile, independently of configuration sharing.

## Model and validation

Add optional `Preferences.siteSearches: [SiteSearch]?`; preserve metadata format3 and old-document decoding. Missing/nil uses built-in YouTube(`yt`), Wikipedia(`wiki`) and GitHub(`gh`) presets. Explicit [] means no shortcuts and survives relaunch. Built-in URLs are HTTPS, with exactly one `%s` placeholder. These defaults are the implementer's call, not a claimed exact Arc list.

`SiteSearch` has UUID id, name, keyword, template and enabled. Normalize names/keywords by trimming and canonical Unicode composition; keywords compare lowercased. Names1...80 characters; keywords1...32 characters, no whitespace/control or `:/?#@%`; Unicode and domain-style dots are supported. Templates are trimmed, at most8192 UTF8 bytes, no whitespace/control, exactly one `%s`, complete literal percent escapes on each side, HTTP(S) with a nonempty host, no user/password, placeholder outside scheme/authority. It may be in path/query/fragment. Query whitespace is trimmed; empty queries do not navigate. Encode query UTF8 with only ASCII RFC3986 unreserved bytes left literal, including escaping percent/plus/slash/ampersand/hash/question marks. Revalidate the final URL and retain the template origin; user query can never change it. Reject a path expansion that forms a dot-only segment and would be removed by URL normalization; query-parameter and safely suffixed templates still represent those queries.

A local `SiteSearchCatalog` validates once per preference revision. Repair takes first valid id/normalized-keyword in input order, at most128; disabled entries remain editable. Upsert rejects invalid data, duplicate keyword or capacity overflow; delete does not recreate defaults. Candidate normal preferences are encrypted before being published. Locked/shutdown/profile-operation states cannot mutate them; a failed save preserves the live catalog and old bytes. Private changes do not read/write normal metadata or keys. No new entitlement/dependency.

## Input behavior

Normal input still searches the web or opens URLs. A matching enabled shortcut appears as a site-search action. Tab activates an exact shortcut or unique keyword prefix; ambiguous prefixes retain native Tab focus behavior. Explicit result selection can choose an ambiguous match. Activated mode shows a bounded site pill and query field; Enter/button submission performs only that site's query. App commands/tab matches do not consume a query while a site is selected. No request occurs during typing, matching, selection or empty submission.

Backspace on an empty site query returns to normal input with the shortcut restored. The pill can clear selected mode while preserving query text. Escape closes/cancels the existing input and resets selection; reopening starts clean. Disabled/deleted/changed site configuration while a query is open produces a local error on submission, not a fallback web search. Configuration changes invalidate a local cache, not the web view or every keystroke.

Add optional native input Tab/empty-Backspace callbacks, defaulting to unhandled. Marked IME composition must be forwarded to AppKit before browser Enter/Escape/arrow/Tab/delete actions. Shift-Tab and unrelated fields retain native behavior. Both primary FocusedInput and compact QuickBrowseInput follow this rule.

## Ownership and routing

Capture a command context when editing starts: primary Space/profile/focused-tab plus optional Peek lifetime UUID, or compact page/profile plus optional Peek lifetime UUID. Before submission compare it with the live context and require the actual profile available. A profile/Space/tab/Peek ownership change cannot send a draft into another account. Clear primary command drafts on explicit Space/tab changes and close; stale snapshots still reject. Ordinary primary and site-query navigation share correct visible-pane/Peek routing. Command-L displays the actual visible URL. Command-T keeps existing new-tab/cancel semantics and does not create a tab until valid submission.

For a primary existing-page input, navigate its own Peek if present, otherwise its focused split pane. A new-tab input creates/selects the correct profile's normal tab, closing the old primary Peek if needed. Compact input navigates its own Peek or quick page, even when the primary window's active profile differs. Preserve live web-host identity through input/pill/setting changes. Existing URL, private profile and selected-file policies remain intact.

## UI

Add Site Search Settings to the command list, app menu and Settings. A separate native panel lists enabled toggles, edit/delete actions and an editor for name/shortcut/template, with a `%s` explanation and optional preset prefills. Save validates with inline errors; remove affects only configuration. Show shared-normal versus temporary-private scope, paused-save status and Done. Fit existing600pt panel/available-height scrolling. Use existing theme/style; no external assets.

Primary mode shows candidates, a selected-site pill and a query submit row. Compact mode uses a short Tab hint/help and a bounded pill/clear action within the existing address area; keep room for query text and overflow actions at480pt/text1.35. Do not add a key-stealing popover or remount the web content. Provide meaningful accessibility labels for selected site, query, activation and exit.

## Verification and remaining scope

Core checks pin encoding/injection/Unicode/template limits, malformed metadata repair and nil/empty/default round trips. Owned store checks pin durable encrypted edits, failure rollback, private nonpersistence, scope invalidation and correct primary/split/Peek/compact routing. A loopback fixture with real normal-profile and private WebKit stores proves decoded query and account isolation, and no requests before explicit submission. Native owned field/delegate checks cover Tab/backspace/default/marked-text behavior; hidden hosting geometry/renders cover selected input and settings at small/large sizes. These are not live keyboard, animation or VoiceOver evidence.

Run all existing checks, both optimized architectures and exact signature/Info/six-entitlement gates on final sources; one fresh whole-plan reviewer and one RED→GREEN fix pass. Keep macOS14, metadataformat3, unsigned labels, current public0.6.2 and its assets unchanged. Do not publish a new tag merely for this source increment. Native access remains unconfirmed; all original UI/full-browser/security/performance/hardware/install gates remain open. Automatic OpenSearch discovery and activation prompts remain further site-search fidelity work; Air Traffic Control is a separate pending subsystem.
