# Alcove

A native, open-source WebKit browser for Mac, inspired by Arc’s sidebar, Spaces and focused browsing workflow. Independent project; no Arc code, trademarks or assets are included.

**Status: 0.2 unsigned preview.** Useful for testing, not yet recommended as your primary browser. No account or subscription is required. macOS 14 or newer; Apple Silicon and Intel.

## Download

Download the universal ZIP (or DMG when offered) from [GitHub Releases](https://github.com/SinfulSoul007/alcove/releases). The app is self-contained: you do **not** need Xcode or developer tools to use a download. Open the DMG and drag **Alcove.app** to Applications, or unzip it and move the app there.

**The preview is ad hoc signed, not Developer ID signed or notarized by Apple.** Gatekeeper may warn or block it. Do not disable Gatekeeper or other system protections to run it. If macOS blocks this preview, build from source or wait for a notarized release. Published SHA-256 checksums identify the release files; they are not an independent security certification.

## Features

- Sidebar tabs, pinned tabs and named Spaces.
- Folders for pinned tabs; right-click a tab to organize it.
- Split view and a keyboard-driven address/search command bar.
- Private windows with temporary WebKit storage and no saved session/history.
- Bookmarks, searchable history, closed-tab restore and an archive library.
- Find in page, zoom, back/forward gestures, reload/stop.
- Download destination picker and a window-local status list.
- File uploads and camera/microphone permission prompts.
- Encrypted local sessions, bookmarks, history and preferences using CryptoKit AES-GCM and a macOS Keychain key.
- App Sandbox and Hardened Runtime, with release Web Inspector access disabled.
- Optional background-tab suspension and auto-archive. Both are off by default.

Spaces organize tabs but **share website logins**. Private windows use separate in-memory website storage. The split-view toolbar operates on the primary tab.

## Privacy and security

Alcove has no analytics, sync server or account service. Sites you visit receive their normal web requests; searches go to DuckDuckGo. No remote search suggestions are sent while you type.

Alcove metadata is encrypted on disk. WebKit manages cookies, caches, website storage and rendering processes separately; they are **not** covered by Alcove’s metadata encryption. Keep macOS current for WebKit security updates. Encryption does not protect against malicious software already running as you or an unlocked, compromised Mac. It is not a substitute for FileVault and OS account security.

Normal metadata is saved to the app’s sandbox Application Support directory, under `OpenBrowser/session.sealed`. On a standard macOS install this is `~/Library/Containers/dev.openbrowser.mac/Data/Library/Application Support/OpenBrowser/session.sealed`. The key stays in Keychain and is not included in downloads, source, or metadata files. Copying this encrypted file to another Mac alone is insufficient to restore it. If the key cannot be read or the file is corrupt, Alcove disables saving rather than overwrite existing data.

Private windows do not read/save normal sessions or history. Downloads you explicitly save remain on disk. Private browsing does not make you anonymous to websites, your network or your provider. OS-level artifacts and website fingerprinting are outside this feature’s guarantees.

Settings includes history deletion and website-data clearing. Clearing website data signs you out and closes this window’s tabs; bookmarks and downloaded files remain. Deleted data may still exist in backups or filesystem snapshots; Alcove does not promise secure erasure.

Camera/microphone requests ask for permission for the focused HTTPS origin. macOS permission controls also apply. Location, web notifications and full site-permission management are not supported in this preview. WebKit’s normal TLS validation is retained; there is no certificate-error bypass.

See [SECURITY.md](SECURITY.md) for the threat model and reporting. This release has received source review and limited automated/manual verification, not an independent security audit.

## First-prototype migration

The first `Browser.app` prototype used unsandboxed, plaintext `session.json`. Its data is not silently read from outside the sandbox. To bring those tabs into Alcove, choose **File → Import Preview Session…**, then select `~/Library/Application Support/OpenBrowser/session.json`. Spaces are added without replacing current tabs. The original JSON is kept and contains readable URLs; manage that original file yourself.

If a legacy `session.json` already exists inside Alcove’s own storage directory, startup migrates it to encrypted metadata before removing that in-container legacy file. Existing unrelated browser profiles are never imported automatically.

## Build from source

Install Apple Command Line Tools, then:

```sh
./scripts/build.sh test
./scripts/build.sh
open build/Alcove.app
```

No package downloads required. `Package.swift` also supports `swift build` on a healthy SwiftPM installation, but that executable is not the sandboxed app bundle: use the build script for app testing. The direct compiler scripts work around the original development machine’s inconsistent SwiftPM installation. `BROWSER_SDK` overrides SDK selection; `BROWSER_ARCH` and `BROWSER_OUTPUT` override architecture and app output. When installed, MacOSX26.5.sdk is preferred on that machine. Minimum target stays macOS 14.

Create verified universal release archives with:

```sh
./scripts/package.sh
```

This runs core/store checks, compiles both architectures, combines the executable, signs it ad hoc with sandbox/hardened-runtime entitlements, verifies signatures/architectures, generates an icon, and produces a ZIP and SHA256SUMS.txt, plus a DMG when disk-image services are available under `dist/`. It does not publish anything or use paid signing credentials. See [RELEASE.md](RELEASE.md).

## Shortcuts

| Shortcut | Action |
| --- | --- |
| Command-L / Command-T | Address bar / new tab |
| Command-W / Command-Shift-T | Close / reopen tab |
| Command-Shift-N | New private window |
| Command-Option-N | New Space |
| Command-F | Find in page |
| Command-D | Bookmark page |
| Command-Shift-B | Library |
| Command-comma | Settings |
| Command-R | Reload |
| Command-S | Toggle sidebar |
| Command-Shift-P | Pin/unpin |
| Command-Shift-D | Split view |
| Command-plus / Command-minus / Command-0 | Zoom in / out / reset |
| Command-[ / Command-] | Back / forward |

## Still needed before a stable release

Broader website/login/media/download compatibility testing; accessibility and keyboard polish; permission revocation UI; safe update delivery; password-manager integration; independent security review; performance/energy benchmarks; phishing/malware protection strategy; full bookmark import/export and isolated profiles. WebKit does not automatically make Chrome extensions compatible.

Arc-inspired next steps include Peek previews, Favorites, better tab dragging, site search and Little Arc-style link windows. Sync and AI features are intentionally outside the preview. No Safari-equivalent speed or complete-security claim is made.

Optional tab suspension can stop background media and lose unsaved page state. Optional archive preserves pinned tabs and each Space’s selected tab, and offers restore from the Library. These controls require deliberate opt-in.

## License

MIT for this repository’s code. Apple frameworks retain their own terms.
