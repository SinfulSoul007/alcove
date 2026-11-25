# Reader mode validation and current gates

This is a local Reader increment on top of 1ae53e659cf9be38470b6a6968a197b1d9113821, with no release/version/engine changes.

## Architecture and resources

Mozilla Readability 0.6.0 is vendored at immutable commit 04fd32f72b448c12b02ba6c40928b67e510bac49. `Sources/Browser/ReaderAssets/NOTICE.md` records source, hash and complete Apache-2.0 notices. No dependency is downloaded at runtime. The manual build copies ReaderAssets beside standalone native fixture executables and into app Contents/Resources; SwiftPM copies the same directory as a target resource.

The extractor runs on a clone in its own WKContentWorld, bounds source elements/text/attributes/comments before cloning, and serializes only structural HTML plus credential-free HTTP(S) links. The renderer is a separate ephemeral WKWebView with content JavaScript off, no extension controller or native message handlers, no subresources, restrictive CSP, and a narrow navigation delegate. The original registered view remains mounted. Captured document/presentation/profile/window identities revoke extraction, rendering, links and find after navigation, handoff, close, disposal and clearing.

## Reproducible gates

Native (macOS14+ app, fixture extension assertions require15.4+):

```sh
BROWSER_SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk scripts/build.sh reader-extraction-test
BROWSER_SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk scripts/build.sh reader-mode-test
```

The lifecycle fixture uses only a loopback HTTP server, a random owned profile, temporary encryption key, and ownership-journal cleanup. Its synchronous AppKit main schedules main-actor async work and calls NSApp.run(). A watchdog retains ownership journals for recovery if cleanup cannot complete. `reader-mode-checks --cleanup-owned-stores` removes only recorded test UUIDs.

Optional fast DOM gate (test-only dependency, never bundled):

```sh
npm install --prefix /tmp/alcove-reader-dom-tests --ignore-scripts --no-audit --no-fund jsdom@26.1.0
NODE_PATH=/tmp/alcove-reader-dom-tests/node_modules node scripts/ReaderExtractionDOMChecks.cjs
```

This runs the actual vendored extractor/wrapper in jsdom with article scripts, event handlers and external resources disabled. It checks extraction, chrome removal, headings/emphasis, relative links, original DOM/form/global preservation, hostile elements/attributes/schemes, short/unsupported pages, and pre-clone budgets for body/head/attributes/comments, document-level nodes and source nesting. jsdom is not a visual or native lifecycle test.

## Results recorded 2026-11-24

- Host SDK26.5 arm64 macOS14 warnings-as-errors typecheck of the complete app + native Reader fixtures passed after the final lifecycle and link-routing review changes.
- Standard development app build succeeded arm64, ad hoc signed; strict code signature verification and pinned packaged Readability hash passed. No installed app/profile was launched or modified.
- Existing core checks:34 passed. Host `swift test` cannot launch the installed swift-package because its BuildServerProtocol framework has a missing symbol; no SwiftPM test result is claimed.
- DOM gate:16/16. A real RED run exposed unbounded head/attribute/comment cloning; all three regressions passed after the source-budget fix. A second RED run caught document-level comments and pathological nesting; both passed after extending the bounded preflight.
- Dedicated VM extraction job `job-reader-green-extraction3`:7 checks passed, including exact original DOM/form/global/scroll preservation. The second extraction encountered WKError5; its WKNavigationDelegate reported source WebContent termination and even primitive42 was unavailable. This is an open native gate, not a successful hostile-markup native run.
- Dedicated VM lifecycle job `job-reader-native-mode2`:7 initial checks passed (native action, source ownership/window, mounted original, isolated ephemeral renderer, content JavaScript off, structured article, CSP). The appearance/scroll assertion failed, followed by WKError5 reading the original source. Owned controller/store cleanup both succeeded. Later lifecycle cases did not run. The VM session is locked; an unlock request already exists in the parent task. No native control/lifecycle success is inferred from the source or DOM gate.

## Remaining gates and limits

Rerun both native Reader gates after the dedicated VM is unlocked, with the strict original form/DOM/scroll assertions unchanged. Observe actual normal/split/Peek/Quick layouts, focus, popovers, keyboard/IME behavior, light/sepia/dark typography, scrolling and links. Reader controls, return/restore, find, stale callbacks, normal protection, Command-click, all context ownership, handoff, window close and profile clearing remain gated until the complete native fixture passes. Intel build and the full package suite for this Reader branch remain open; the parent's successful base preview CI does not cover Reader.

Remote images/media, interactive widgets, cross-origin iframe articles, very short articles, PDFs/non-HTML documents and oversized documents are unsupported. Image alt text/captions can remain. The original webpage keeps running under Reader. Reader appearance is session-local. Saving/printing explicitly targets the original page. Extension reader flags remain refused. No GUI/pixel/animation claim is made, and this increment does not complete the broader browser project.

The final local candidate also includes guarded keyboard focus (the covered source resigns focus during preparation; the ready article receives focus only in its own active pane/window), same-store Quick/Quick Peek cancellation, subtree-scoped theme, link preview/DNS-prefetch disable, and captured-profile modifier-link routing. Those review changes passed complete warnings-as-errors source/fixture typechecking and an exact final arm64 app link, strict code signature verification, and byte-for-byte verification of all five packaged Reader assets. Native fixtures deliberately retain the failing appearance/source assertions and add responder, protection, modifier-link, same-store handoff and clearing assertions. Their complete GREEN remains required before integration; this candidate is not reported as merge/release ready.

## Hosted qualification follow-up

[Run45491231027](https://github.com/SinfulSoul007/alcove/actions/runs/45491231027), exact e9732328a81ab5ef57b65b392b39eb43d1efaa65, failed in the native Reader gate. Extraction passed11/0, including hostile markup. Native appearance controls and exact original DOM/draft/globals/scroll preservation passed with ready/current/same-document state. The first responder assertion failed, followed by a Reader Find timeout; no source WebContent termination was reported. Cleanup succeeded.

The primary fixture had omitted real app activation used by the existing website-protection surface fixture. It now activates the owned app and waits for an actual key window before opening Reader; the strict responder assertion remains. Find now waits for its native text field before entering the query, logs only owned-fixture query/result state, and includes a regression assertion that an identical query assignment preserves the current result. Product bytes are unchanged in this fixture-only follow-up; hosted execution is still required, and the unchanged-query regression is expected to expose the current unconditional search invalidation. No locked-VM native retry was made.
