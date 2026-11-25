# Reader mode validation and current gates

Reader is included in the [public 0.21 preview](releases/0.21.0-preview-verification.md), exact source `57a11f4462204eb380e28a9ab37ea1e7638313c9`. Combined CI passed native extraction 13/0 and native lifecycle 49/0 with owned cleanup true/true, both optimized architectures and universal package checks. Public installer bytes, mounted-DMG contents and signed update behavior were independently verified. The earlier checkpoints below record development evidence; the current release record supersedes their pending integration/publication statements.

## Architecture and resources

Mozilla Readability 0.6.0 is vendored at immutable commit 04fd32f72b448c12b02ba6c40928b67e510bac49. `Sources/Browser/ReaderAssets/NOTICE.md` records source, hash and complete Apache-2.0 notices. No dependency is downloaded at runtime. The manual build copies ReaderAssets beside standalone native fixture executables and into app Contents/Resources; SwiftPM copies the same directory as a target resource.

The extractor runs on a clone in its own WKContentWorld, bounds ordinary and nested template-fragment elements, text, CDATA, attributes, comments and processing instructions before cloning, and serializes only structural HTML plus credential-free HTTP(S) links. The renderer is a separate ephemeral WKWebView with content JavaScript off, no extension controller or native message handlers, no subresources, restrictive CSP, and a narrow navigation delegate. The original registered view remains mounted. Captured document/presentation/profile/window identities revoke extraction, rendering, links and find after navigation, handoff, close, disposal and clearing.

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

## Historical local results before hosted qualification

- Host SDK26.5 arm64 macOS14 warnings-as-errors typecheck of the complete app + native Reader fixtures passed after the final lifecycle and link-routing review changes.
- Standard development app build succeeded arm64, ad hoc signed; strict code signature verification and pinned packaged Readability hash passed. No installed app/profile was launched or modified.
- Existing core checks:34 passed. Host `swift test` cannot launch the installed swift-package because its BuildServerProtocol framework has a missing symbol; no SwiftPM test result is claimed.
- DOM gate:16/16. A real RED run exposed unbounded head/attribute/comment cloning; all three regressions passed after the source-budget fix. A second RED run caught document-level comments and pathological nesting; both passed after extending the bounded preflight.
- Dedicated VM extraction job `job-reader-green-extraction3`:7 checks passed, including exact original DOM/form/global/scroll preservation. The second extraction encountered WKError5; its WKNavigationDelegate reported source WebContent termination and even primitive42 was unavailable. This is an open native gate, not a successful hostile-markup native run.
- Dedicated VM lifecycle job `job-reader-native-mode2`:7 initial checks passed (native action, source ownership/window, mounted original, isolated ephemeral renderer, content JavaScript off, structured article, CSP). The appearance/scroll assertion failed, followed by WKError5 reading the original source. Owned controller/store cleanup both succeeded. Later lifecycle cases did not run. The VM session is locked; an unlock request already exists in the parent task. No native control/lifecycle success is inferred from the source or DOM gate.

## Historical gates before hosted qualification

The hosted baseline result below supersedes the following native and package gates for exact8c530. Its later review fixes still require their own native run.

Rerun both native Reader gates after the dedicated VM is unlocked, with the strict original form/DOM/scroll assertions unchanged. Observe actual normal/split/Peek/Quick layouts, focus, popovers, keyboard/IME behavior, light/sepia/dark typography, scrolling and links. Reader controls, return/restore, find, stale callbacks, normal protection, Command-click, all context ownership, handoff, window close and profile clearing remain gated until the complete native fixture passes. Intel build and the full package suite for this Reader branch remain open; the parent's successful base preview CI does not cover Reader.

Remote images/media, interactive widgets, cross-origin iframe articles, very short articles, PDFs/non-HTML documents and oversized documents are unsupported. Image alt text/captions can remain. The original webpage keeps running under Reader. Reader appearance is session-local. Saving/printing explicitly targets the original page. Extension reader flags remain refused. No GUI/pixel/animation claim is made, and this increment does not complete the broader browser project.

The final local candidate also includes guarded keyboard focus (the covered source resigns focus during preparation; the ready article receives focus only in its own active pane/window), same-store Quick/Quick Peek cancellation, subtree-scoped theme, link preview/DNS-prefetch disable, and captured-profile modifier-link routing. Those review changes passed complete warnings-as-errors source/fixture typechecking and an exact final arm64 app link, strict code signature verification, and byte-for-byte verification of all five packaged Reader assets. Native fixtures deliberately retain the failing appearance/source assertions and add responder, protection, modifier-link, same-store handoff and clearing assertions. Their complete GREEN remains required before integration; this candidate is not reported as merge/release ready.

## Hosted qualification follow-up

[Run45491231027](https://github.com/SinfulSoul007/alcove/actions/runs/45491231027), exact e9732328a81ab5ef57b65b392b39eb43d1efaa65, failed in the native Reader gate. Extraction passed11/0, including hostile markup. Native appearance controls and exact original DOM/draft/globals/scroll preservation passed with ready/current/same-document state. The first responder assertion failed, followed by a Reader Find timeout; no source WebContent termination was reported. Cleanup succeeded.

The primary fixture had omitted real app activation used by the existing website-protection surface fixture. It now activates the owned app and waits for an actual key window before opening Reader; the strict responder assertion remains. Find now waits for its native text field before entering the query, logs only owned-fixture query/result state, and includes a regression assertion that an identical query assignment preserves the current result. Product bytes are unchanged in this fixture-only follow-up; hosted execution is still required, and the unchanged-query regression is expected to expose the current unconditional search invalidation. No locked-VM native retry was made.

[Run45519842986](https://github.com/SinfulSoul007/alcove/actions/runs/45519842986), exact4ffa0e1, confirmed real activation/key-window/responder success and retained all source/appearance passes. Its Find logs captured a second identical `river` publication clearing pending state, followed by the timeout. `searchText` now invalidates requests/results only when its value changes, matching the existing Quick Browse state pattern. Native checks explicitly echo the same query during the request and after its result. Local complete warnings-as-errors typechecking passes; hosted GREEN for this production fix and remaining lifecycle cases is still pending.

[Run45528878992](https://github.com/SinfulSoul007/alcove/actions/runs/45528878992), exactf7016f8, verified the Find fix: visible-article match, identical in-flight query echoes, unchanged completed result, missing text, Escape and exact source restore all passed. Extraction remained11/0. The complete native fixture reached42 checks with one failure: it attempted `moveView` after `acquirePrimaryStore(copying:)` had already claimed and transferred the selected live view. The subsequent Reader cancellation, actual form preservation, destination Reader, window close and profile clear checks passed. The fixture now asserts old-owner removal, destination ownership of the same WKWebView, captured profile and original document identity after that automatic handoff, rather than mutating ownership a second time. Product bytes remain f7016f8; complete hosted GREEN remains pending.


## Successful hosted baseline

[Run45533188518](https://github.com/SinfulSoul007/alcove/actions/runs/45533188518), exact 8c530dd111233bb31b5a4dfa25a18f11a43cd6b5, succeeded. The parent retained its full log at `work/reader-mode-review/ci-45533188518.log`: extraction11/0, native42/0, owned controllers/stores cleanup true/true, full tests, both optimized architectures and universal ZIP/DMG verification. This qualifies the pre-review baseline, not the subsequent fixes below. It closes the preceding historical hosted gates for that baseline.

## Review fix pass recorded 2026-11-24

One bounded pass addressed template fragments, real passage preservation, failed-load completion, missing-href semantics and XHTML CDATA. The iterative preclone traversal visits ordinary children and nested HTML template content with combined budgets and a bounded ancestor stack. Ordinary template-bearing articles remain supported. CDATA is counted as clone input and serialized as escaped text. Missing-href anchors keep their children without gaining navigation semantics; explicitly empty and fragment hrefs retain their existing behavior.

Trusted bundled Style.js captures an actual visible text range, or a visible block fallback, and restores its position through size, typeface and width changes. A user scroll or viewport change establishes a new anchor. Physical document edges can limit restoration. It changes only the isolated Reader document's styles/scroll. ReaderDocument moved unchanged into a Foundation-only file so the real production document can also generate an owned layout fixture.

ReaderLoadState accepts a local article completion once, revokes pending load state on failure, preserves the first failure explanation and rejects late callbacks. Failure stops the renderer's pending load. The completion delegate requires loading/current state and rechecks ready/current after style application, since loading the bundled script can fail synchronously before focus is assigned.

Focused regressions ran against the old behavior before their fixes:

| Gate | Observed RED | Final GREEN |
| --- | --- | --- |
| Template fragments, nesting, combined budgets and missing href | 23 checks,5 failures | 23/0 |
| Real XHTML CDATA preservation and preclone budget | 25 checks,2 failures | 25/0 including preceding cases |
| Production load-state transitions and late completion | 9 checks,3 failures | 9/0 |
| Actual visible-passage layout | 7 checks,4 failures | 7/0 |
| Missing/empty/oversized/valid local style resource | — | 4/0 |
| Existing core checks | — | 34/0 |

Final host checks passed with explicit SDK26.5 and the existing writable module cache: complete app plus ReaderModeChecks typecheck, standalone extraction fixture typecheck, warnings-as-errors, arm64 macOS14 target, standard app build and ad hoc signing, strict deep signature verification, and byte-for-byte comparison of all six packaged Reader assets. Readability SHA-256 remained `34dcab3d0832d0019f02990eed6b6124e029e8c32b9f0c6f2550544ff8dff174`. Canonical `reader-load-test` completed9+4/0. Shell/Python syntax and diff whitespace checks passed. The built app was not launched.

Local evidence is retained outside the checkout in `work/reader-evidence/reader-review-*.log`: template-anchor, cdata, load and style RED/GREEN logs; final DOM, load, resources and core logs; final app/fixture and extraction typecheck logs; canonical-load and app-build logs. The earlier host SwiftPM installation issue remains; no local SwiftPM result is claimed.

The full `scripts/build.sh test` now includes the pure load/resource gate before the existing native gates. It can also run without GUI:

```sh
BROWSER_SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk scripts/build.sh reader-load-test
```

Optional actual-layout checks use a standalone Chrome for Testing headless-shell executable supplied explicitly by the operator:

```sh
xcrun swiftc -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
  -module-cache-path .build/cache -target arm64-apple-macosx14.0 \
  -parse-as-library -warnings-as-errors Sources/Browser/ReaderResources.swift \
  Sources/Browser/ReaderDocument.swift scripts/ReaderStyleFixture.swift \
  -o .build/reader-style-fixture
python3 scripts/ReaderStyleChecks.py --headless-shell /path/to/chrome-headless-shell \
  --fixture-generator .build/reader-style-fixture
```

The generator uses the actual Reader document and Style.js with owned long paragraphs. Only its generated test document permits the inline trusted driver; production CSP remains `script-src 'none'`. The CLI runner uses an owned temporary profile and `--dump-dom`, with no debugger port, process instrumentation or existing browser profile. It checks the same text node, character offset, passage and vertical position after reflow, plus manual scrolling and the article top. These checks supplement native WebKit qualification.

Real-layout qualification used Google's standalone headless-shell158.0.8127.88, mac-arm64, downloaded from the public Chrome for Testing distribution. Sandbox startup denial was an environment failure, not counted as a RED regression; the ordinary authorized CLI invocation produced the reported layout results. No DevTools/debugger, tracing or interposition was used.

## Current remaining gates

The final native assertions for passage identity/position, XHTML CDATA, missing style resources and late failed-load completion passed in exact-source combined CI 45557540457. The optimized Intel build, universal ZIP/DMG and public download/update gates also passed; see the linked release record. Missing-style tests moved only the standalone fixture's copied asset and restored it, preserving all original source DOM/form/scroll and ownership assertions.

Actual normal/split/Peek/Quick layouts, popovers, keyboard/IME behavior, typography and animation still require broader observed GUI and accessibility verification. Native fixture and headless layout results do not imply pixel-level review, minimum-OS or real Intel hardware coverage. Unsupported-content limits remain, and this increment does not complete the full browser goal.
