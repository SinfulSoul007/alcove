# Website fullscreen development verification

This feature remains on `feature/website-fullscreen`; it is not part of public 0.21. Native source `5c358cdb6c3564b0d51fee778dadad36cb52dda0` passes [run45568400725](https://github.com/SinfulSoul007/alcove/actions/runs/45568400725): **183 assertions, zero failures**, all ten regular/private page contexts completed and owned extension/website cleanup true/true. Whole-feature integration and release are unfinished.

## Implemented and observed

Actual browser-page configurations enable the public Fullscreen API through the real-page `SplitDropWebView` initializer. Reader/internal views use their separate restricted configurations. Per-view residency captures the logical browser window, profile/presentation and latest intended host. It preserves WebKit's borrowed view and placeholder through SwiftUI remounts, resizing and host replacement. Reconciliation uses public state/view-move signals, runs after the native operation returns, and waits for the captured fullscreen window to disappear. The original host's weak restoration registry supplies the later native subview-removal signal; no private class name or timed delay is used.

The native witness exercises generic-element and playing-video Fullscreen API requests in tabs, actual native split panes, primary Peek, Quick Browse and Quick Peek, each in normal and private contexts. It checks separate native-window borrowing, logical window/profile identity, resize/remount, a replaced host, actual viewport, exact live view/document token, unsaved form, scroll and navigation history. Repeated entry waits for real native-window completion. No user profile, Keychain, global desktop input or process tracing is used.

## Regression evidence

- Test-only `b75b89f`, run45561594909: 19 assertions / four expected failures. Production fullscreen was disabled; generic/video remounts and a replacement host reclaimed WebKit's borrowed view. Native entry/placeholder/window and source-state controls succeeded.
- An independent stock `WKWebView`/plain `NSView` control at `4f08494`, run45565669961, proved genuine entry for both exit methods. `document.exitFullscreen` physically restored the original host/window. `closeAllMediaPresentations` left state zero and a detached view after the deadline. Normal fullscreen exit is qualified through the document method in the client content world; native close-all is not assumed safe for active fullscreen on this hosted OS.
- Full app run45566217451 at `17deaed` passed the original regressions and nine contexts, with one private-tab second-exit timeout: 157 assertions / one failure, cleanup true/true.
- Expanded unchanged-source regression `b6ccb467`, run45567616193: 22 assertions / three expected failures. Every original presentation reported restoration complete while its native fullscreen window was still visible. The original page/state controls still passed.
- Source `5c358cd` adds the real native completion barrier. The unchanged completion regression and all ten contexts pass 183/0 in run45568400725. Complete source/fixture SDK26.5 warnings-as-errors typechecking also passes.

The owned local HTTP/video fixture pins the unmodified WebKit test clip to source `26695efdefc6076049ec50713a2c4e54b90b4d47` and SHA-256 `c2f0f7007861ab196d31d6d9d62a01e4bd4a4158b2d6cd696105c09e9d8d61e6`. It is downloaded only for testing and is not a product asset.

## Remaining gates

Task2 still requires captured-window command routing, coalesced once-only exit/cancellation, Escape/Cmd-W/address/find/Reader/output, visible source-bound prompts/warnings, focus/stale callbacks, cleanup protection, close/clear/shutdown and live view transfer. Website popup behavior and full native-video/PiP paths are not established by element requests on a video. Fresh no-media documents failed stock entry on this hosted OS before the decoded-media control; all-site startup behavior remains open. No silent bootstrap workaround is claimed.

Relevant existing Reader/chrome/profile/output regressions, both optimized architecture builds, universal package gates, one fresh whole-branch review and installed/live visual/keyboard/animation/accessibility/minimum-OS/Intel checks remain. The witness runs on a hosted arm64 Mac using SDK26.5 with a macOS14 compilation target. This does not establish minimum-OS or real Intel behavior, Arc parity, Safari speed or completion of the full browser objective.
