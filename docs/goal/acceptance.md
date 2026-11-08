# Full browser acceptance ledger

The active user goal remains: a fully built browser with regular updates, Arc's full feature set and visually correct behavior, extensive themes/customization, a polished first-launch animation, and a smooth sidebar. A passing preview or a partial feature list does not complete this goal.

Published 0.4 artifacts and public update selection have been verified. Published 0.5 adds isolated profiles and profile-owned Favorites; current 0.6 work adds Quick Browse; the full goal remains in progress.

## Acceptance areas

| Requirement | Current evidence | Status / remaining evidence |
| --- | --- | --- |
| Downloadable app and DMG | 0.4 universal ZIP/DMG, public checksums and mounted-image verification | Implemented; minimum-OS and quarantined-install QA still needed |
| Regular updates | In-app manual/opt-in daily checks, channels, strict release selection and repeatable CI/tag workflows | Implemented and behavior-tested in 0.4; public 0.4 tag/download selection verified; native update panel QA pending |
| Arc sidebar / resizing / navbar | Arc inspected; 0.3 native checks; 0.4 keeps web/sidebar mounted, uses transient drag and delayed hover | State tests pass; 0.4 native resizing, hover/animation and minimum-window visual QA still pending |
| Themes / extensive customization | Twelve presets, custom gradients/accent, density/text/radius/icons/motion, responsive Favorites and preview | Implemented; bounds/contrast/persistence tests pass; native appearance/color-picker/layout QA pending |
| First-run experience | Animated native introduction, theme/setup steps, skip/replay and reduced motion | Migration/private/locked/retry tests pass; native animation and keyboard QA pending |
| Tabs / pins / Favorites / folders | 0.3 behavioral and native checks | More edge-case QA; nested folders and richer organization remain |
| Spaces / isolated profiles | Named WebKit stores, encrypted profile libraries, durable clear/delete recovery and shared profile Favorites | Real cookie/localStorage, relaunch, clear and deletion isolation checks pass; native profile controls/confirmation/keyboard QA pending |
| Peek / Little Arc | Shift-click Peek plus current 0.6 Quick Browse compact windows, profile memory, live handoff and recovery | Native visual/keyboard/animation verification and broader routing/gesture fidelity remain open |
| Split view | Two panes with focus routing | More panes, resizing/split lifecycle and full native QA |
| Air Traffic Control / site search | None | Implement routing rules and keyword site search |
| Boosts / Easels / capture | None | Implement website customization and a local canvas/capture workflow |
| Extensions / browser integrations | None | Investigate and implement supported WebKit extension path; don't claim Chrome parity without real compatibility evidence |
| Everyday browser essentials | Basic bookmarks/history/find/downloads/zoom | Import/export, downloads manager, print/save, permissions, audio/media, reader and additional keyboard/accessibility work remain |
| Privacy / security | Sandbox, encrypted metadata, private store, request-specific media prompt | Profile isolation and failure/recovery tests pass; independent audit, richer permissions and adversarial navigation tests remain |
| Performance / reliability | Functional tests; no Safari benchmark | Measure startup, frame responsiveness, many-tab memory, site compatibility, crash/recovery and energy |
| Updates/distribution trust | Ad hoc signing, no Developer membership | Trusted signing/notarization unavailable; retain accurate unsigned labeling and never weaken Gatekeeper |

Full parity inventory reference: official Arc desktop feature resources and release notes, including Favorites, pins, Today/archive, folders, Spaces/profiles, Peek, Little Arc, Air Traffic Control, site search, Boosts, Easels/capture, extensions and media. The implementation will be independently written; Arc source/assets and private browsing data are not copied into this repository.

## Work records

- Initial pass: acceptance and authoritative-state inspection; sidebar/customization/first-run and update infrastructure are independent workstreams.
- 0.4 implementation: 153 behavioral checks pass across core/store/appearance/updates, plus ZIP verification. Both architectures compile. The local DMG mounts, matches the universal executable and Info.plist, carries sandbox entitlements/license and has the Applications link. This is compiled/structural evidence, not Intel-hardware, macOS-14 or quarantined-install evidence.
- Independent source review caught and fixed legacy first-run replay, private welcome replay, opt-out checks, missing recurring cadence, legacy unlock migration and failed-save retry duplication. Unlock now persists the candidate before publishing it to live state.
- Visual QA limitation in this turn: Arc is readable through Computer Use. The new isolated test app needs app-access approval; the older review identity can be read but clicks fail through a stale macOS app path. No 0.4 native screenshot/animation success is claimed from source checks.

- 0.5 profile increment: 264 browser checks pass, including real named WebKit storage separation and clear/delete isolation. A fresh whole-branch review found two command/import paths; both have failing-before/passing-after regressions. Universal ZIP/DMG built and mounted locally. Native visual/keyboard QA remains pending; the full goal is active.

- 0.5 published at b7139e5: CI 42462909134 and release 42463181857 passed. Public ZIP/DMG were downloaded back, checksums/signature/universal slices/mounted contents verified, and the live 0.4 update client selected and verified 0.5. See docs/releases/0.5.0-verification.md for evidence and recorded decisions. Native visual QA and the broader goal remain open.

- 0.6 development: profile-owned Quick Browse metadata/lifecycle passed 365 checks before window integration. Compact native ownership, command search, archive/filter/settings and permission-sheet guards are now integrated. Focused hidden-window and real-page checks cover lifecycle and state preservation; full final suite/build/review/publication are pending. Hidden-window checks do not establish visual/animation/keyboard fidelity.

- 0.6 review fix pass: 427 checks pass, zero diagnostics; both optimized architecture/signature/Info gates pass. Four fresh-review findings were reproduced and fixed: independent Peek state, correct handoff/foreground targeting and primary-close native teardown. A coupled stale-Peek-URL media race also has RED→GREEN coverage. Source CI and publication/download-back verification are pending; all native/full-browser gates stay open.

- 0.6 published at 16d98ff: source CI 42510440221 and release 42511262876 passed. Public ZIP/DMG were downloaded back and their checksums, signatures, universal slices, mounted contents and exact entitlement set verified. The live 0.5 preview update client selects/verifies 0.6; 0.6 reports up to date. See docs/releases/0.6.0-verification.md for all 30 implementation/review decisions. This is progress; the original full goal remains active.
- Static UI fixture baseline now exists without reading real user data or controlling a desktop app. Hidden-host renders include the sidebar at normal and large text/minimum-window sizes. Component geometry exposes a titlebar/header alignment discrepancy (native center 16pt; primary header 20pt; large-text quick header 28.95pt). Native app interaction, resizing/animation and Arc fidelity still need direct verification. Next visual work should correct and verify this geometry rather than treat compilation or fixture renders as perfection.
- Post-0.6 native chrome increment: shared measured AppKit/SwiftUI baselines correct primary, collapsed-sidebar and Quick Browse alignment. Thirty focused checks pass, including six RED→GREEN regressions for clipped Quick Browse actions and actual native viewport hit testing. Owned renders confirm both 760pt and 480pt action menus remain visible at text1.35. See `native-chrome-verification.md`; live native animation/fullscreen/accessibility and the complete browser goal remain open.
