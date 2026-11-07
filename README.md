# Alcove

Alcove is a native, Mac-only, open-source browser prototype inspired by sidebar-based browsing. SwiftUI + AppKit provide the interface; the macOS WebKit framework renders websites. Independent project, unaffiliated with Arc or The Browser Company. No Arc source code or assets are included.

The development app and build target are currently named `Browser`.

Requires macOS 14 or newer and Apple Command Line Tools (`xcode-select --install`). No third-party packages.

## Build and run

```sh
./scripts/build.sh test
./scripts/build.sh
open build/Browser.app
```

The build script compiles directly with `swiftc`, bundles the executable, and signs the app locally with an ad hoc signature. Set `BROWSER_SDK=/path/to/MacOSX.sdk` to override SDK selection. It uses the installed MacOSX26.5 SDK when present to work around a mismatched default SDK on the initial development machine.

`Package.swift` also supports `swift build` / `swift test` on a healthy Swift Package Manager installation. `swift run Browser` runs the executable without the app bundle; prefer the bundled build.

## In this preview

- Sidebar with pinned and regular tabs; right-click to pin, close, move between Spaces, or show a tab beside the current one.
- Named Spaces with separate tab collections. Spaces share the same WebKit website data store and logins; they are not isolated browser profiles.
- Address/search command bar with open-tab suggestions and DuckDuckGo search.
- Back/forward, reload/stop, swipe navigation and split view.
- Persistent sessions and cookies, lazy page creation, and a six-web-view cache. Inactive loaded tabs can be discarded when opening more tabs. Their URLs remain, but back/forward history, unsaved forms, playback, and other page state may be lost.
- Basic download destination picker, popup tabs and JavaScript dialogs.
- Native Edit menu and inspectable WebKit views.

## Shortcuts

| Shortcut | Action |
| --- | --- |
| Command-L | Open address/search bar |
| Command-T | New tab |
| Command-W | Close tab |
| Command-R | Reload |
| Command-S | Toggle sidebar |
| Command-Shift-N | New Space |
| Command-Shift-P | Pin/unpin tab |
| Command-Shift-D | Toggle split |
| Command-[ / Command-] | Back / forward |
| Escape | Close command bar |

Sessions are saved atomically to `~/Library/Application Support/OpenBrowser/session.json`. WebKit manages cookies and website storage through its default persistent data store. The application has no account system, analytics, or sync service. It makes requests to the sites you open and DuckDuckGo when you search.

## Status and limits

This is an early prototype, not a fully audited daily-driver browser. It has no extensions, folders, bookmark import, password manager integration, dedicated history UI, find-in-page, website permission controls, private browsing, sync, automatic tab archive, download manager, or automatic updates. External app URL schemes are blocked. Split-view toolbar actions operate on the primary tab. Memory capping can interrupt background activity. WebKit security updates come with macOS updates. Safari-equivalent performance has not been established; benchmark startup, page loads, memory and energy use before making performance claims.

The local build is ad hoc signed, not notarized. Public distribution needs a developer identity, hardened runtime/entitlement review, permission handling and notarization. Source repository: https://github.com/SinfulSoul007/alcove.

## Tests

`./scripts/build.sh test` runs framework-independent core checks, including address resolution, query encoding, unsupported schemes, tab closure and session persistence. `Tests/BrowserCoreTests` contains the equivalent XCTest suite for full Xcode installations. UI and real-site behavior require additional manual testing.

## License

MIT for this repository's code. Apple's system frameworks retain their own terms.
