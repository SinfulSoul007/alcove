# Owned layout measurements — 2026-11-08

These measurements cover layout calls in Alcove's own never-shown AppKit/SwiftUI host. They do not establish onscreen frame rate, animation smoothness, complete Arc fidelity or Safari-equivalent performance.

## Reproduce

Run `scripts/benchmark-layout.sh work/layout-benchmark.csv` on a Mac with the command-line developer tools. It builds optimized code for the local architecture and prints the browser source revision. CSV samples are written to the specified path.

The fixture uses a private store, a disposable UserDefaults suite,49 dummy sidebar tabs and one empty nonpersistent WebKit view. It neither reads real sessions/Keychain data nor orders a window, operates another app, generates global input or captures the screen. The defaults suite is removed on completion. Native mouse event objects are sent directly to the owned grip's handlers.

Forty window sizes and30 sidebar drag steps run at each text scale. Animations are off. Each sample times the synchronous size/event call plus forced layout, then records a separate settled duration after a five-millisecond own-process event pump and another layout. Only the synchronous durations are summarized below. This does not include display presentation, a real loaded site's work or a compositor deadline.

## Observed baseline

Browser source: `2250ccf4af47b36432eeb2fa303d3ab824c64939`. Local arm64 host, macOS26.7.1 build25G241. One exploratory CLI run; other system work was not controlled. Quantiles use the sorted sample order statistics in the tool; they are not confidence estimates.

| Operation | Text scale | Samples | p50 | p95 | Maximum |
| --- | --- | --- | --- | --- | --- |
| Window size/layout | 1.0 | 40 | 3.97ms | 9.25ms | 16.52ms |
| Window size/layout | 1.35 | 40 | 3.70ms | 7.82ms | 16.61ms |
| Sidebar drag/layout | 1.0 | 30 | 3.58ms | 4.23ms | 5.18ms |
| Sidebar drag/layout | 1.35 | 30 | 3.81ms | 5.39ms | 5.77ms |

The window-size samples emitted zero `BrowserStore.objectWillChange` notifications at both scales. Every sample retained the same mounted WebKit view. Sidebar release saved326pt only to the disposable suite. Actual web-view widths changed across both size and drag samples, so the measurements did not time an unchanged layout.

An earlier direct compile/run showed variation (normal-text window p95=11.67ms, maximum18.86ms). The difference reinforces the need for repeated controlled native profiling before making responsiveness claims. These records provide a starting point for finding expensive layout work; startup, loaded/many-tab memory, actual frame timing, energy and Safari comparisons remain open.
