# Alcove

A native, open-source WebKit browser for Mac, inspired by Arc’s sidebar, Spaces and focused browsing workflow. Independent project; no Arc code, trademarks or assets are included.

**Status: experimental, unsigned preview.** Useful for testing, not yet recommended as your primary browser. No account or subscription is required. macOS 14 or newer; Apple Silicon and Intel.

## Download

Download the universal ZIP (or DMG when offered) from [GitHub Releases](https://github.com/SinfulSoul007/alcove/releases). The app is self-contained: you do **not** need Xcode or developer tools to use a download. Open the DMG and drag **Alcove.app** to Applications, or unzip it and move the app there.

**The preview is ad hoc signed, not Developer ID signed or notarized by Apple.** Gatekeeper may warn or block it. Do not disable Gatekeeper or other system protections to run it. If macOS blocks this preview, build from source or wait for a notarized release. Published SHA-256 checksums identify the release files; they are not an independent security certification.

## Features

- Compact, resizable Arc-style sidebar with Favorites tiles, pinned tabs/folders, Today and named Spaces.
- Twelve per-Space themes, custom gradients/accent colors, Space icons and a live appearance preview.
- Tab density, text size, corner rounding, responsive Favorite columns, icon/close-button visibility and reduced-motion support.
- A bottom Space dock and delayed collapsed-sidebar edge reveal; sidebar drag width saves on release.
- Animated, skippable first-launch setup, plus a replayable welcome tour. Existing sessions and private windows skip setup.
- Manual GitHub update checks, stable/preview channels and optional daily checks. Downloads and installation remain explicit actions.
- Drag tabs between sections and into folders. Pinned tabs keep their title and saved home URL when closed.
- Folders for pinned tabs; right-click a tab to organize it.
- Split view with actions targeted to the clicked pane.
- Keyboard-driven command bar with tab switching, Pin/Favorite commands and no empty tab created on cancellation.
- Shift-click Peek previews in their originating main or compact window, with close and open-in-Space controls.
- Quick Browse compact external-link windows, exact-host profile memory, same-link resurfacing and live page handoff into a Space. Forms, scroll and navigation history survive a same-profile handoff.
- Named profiles with separate website logins/storage, Favorites, bookmarks, history, closed tabs and archives. Multiple Spaces can share a profile.
- Private windows with temporary WebKit storage and no saved session/history.
- Bookmarks, searchable history, closed-tab restore and an archive library.
- Find in page, zoom, back/forward gestures, reload/stop.
- Download destination picker and a window-local status list.
- File uploads and camera/microphone permission prompts.
- Encrypted local sessions, bookmarks, history and preferences using CryptoKit AES-GCM and a macOS Keychain key.
- App Sandbox and Hardened Runtime, with release Web Inspector access disabled.
- Optional background-tab suspension and day-based Space-tab archive, both off by default. Quick Browse defaults to six-hour inactivity archive, with Off/6/12/24-hour choices.

Spaces using the **same profile share website logins**; different profiles use separate WebKit data stores and library records. Existing Spaces stay on the default profile so their logins survive the upgrade. Private windows use their own in-memory website storage. Click a split pane to direct navigation, find and other page actions to it.

Use **Alcove → Manage Profiles…**, Settings, or the Space menu to create and assign profiles. Creating a profile opens a new Space. Changing a Space’s profile or moving a tab across profiles reloads its pages after confirmation; saved URLs are kept, but unsaved forms cannot be transferred. Cookies never move between profiles. Favorites belong to their profile: changing a Space shows its new profile’s collection and preserves the previous collection, even if it has no Spaces. Selecting a Favorite keeps the current Space. Delete a named profile only after moving its Spaces elsewhere. The default profile can be cleared but cannot be removed.

Interrupted deletion or website clearing stays marked for retry in profile management. A pending profile cannot open its persistent website store for browsing. Window closure does not let a stale callback overwrite a reopened window’s state. Retry completes the pending operation and preserves links queued after its initial tab reset.

## Quick Browse

Use **File → New Quick Browse** (Option-Command-N), or open a web link from another app after selecting Alcove as your default browser in macOS. Reopening the same external URL resurfaces its existing compact window within the chosen profile. Each explicit blank Quick Browse request opens a separate window. A private window can create private quick pages; incoming external links always use the normal owner.

The compact window has its own address/find fields, profile selector and **Open in Space** menu. A same-profile handoff keeps the actual live website, including forms, scroll and back/forward history. A different profile requires reload consent and never copies cookies. Profile choices can be remembered for an exact hostname; subdomains do not inherit them. A paused remembered profile blocks the link until recovery instead of using another account. Forget choices or opt out of compact external windows in Settings.

Quick pages stay independent when their intended Space changes or disappears. Closing the main window keeps the same browser store alive while compact windows remain. Command-N reopens the main window; closing the last window disposes its store, and Alcove stays in the menu bar until Quit. There is still only one normal primary window at a time.

Quick pages and their archive are encrypted with their owning profile’s metadata. The default inactivity archive is six hours. Focused/loading pages, active playback/capture and open native sheets are kept; unknown media state is retained for a later check. Archiving closes live state and can discard unsaved forms. Choose **Off** to keep pages open. Use **Library → Archive → Quick Browse** to reopen in a compact window or directly in a matching-profile Space. Private quick records and preferences remain in memory only.

## Privacy and security

Alcove has no analytics, sync server or account service. Sites you visit receive their normal web requests; searches go to DuckDuckGo. No remote search suggestions are sent while you type.

Profiles separate website storage and organization within one Mac account; they are not separate user accounts or protection against someone using the unlocked app.

Alcove metadata is encrypted on disk. WebKit manages cookies, caches, website storage and rendering processes separately; they are **not** covered by Alcove’s metadata encryption. Keep macOS current for WebKit security updates. Encryption does not protect against malicious software already running as you or an unlocked, compromised Mac. It is not a substitute for FileVault and OS account security.

Normal metadata is saved to the app’s sandbox Application Support directory, under `OpenBrowser/session-v2.sealed`. On a standard macOS install this is `~/Library/Containers/dev.openbrowser.mac/Data/Library/Application Support/OpenBrowser/session-v2.sealed`. The key stays in Keychain and is not included in downloads, source, or metadata files. Copying this encrypted file to another Mac alone is insufficient to restore it. If the key cannot be read or the file is corrupt, Alcove disables saving rather than overwrite existing data. Startup does not display a blocking authentication prompt; use the explicit Unlock action if Keychain access is required. Local saving remains visibly paused until recovery succeeds.

Private windows do not read/save normal sessions or history. Private windows inherit cosmetic appearance only, and changes inside them are temporary. Per-Space colors and appearance preferences are encrypted with normal metadata. Sidebar width and the last automatic update attempt are ordinary local UI defaults, outside metadata encryption. Downloads you explicitly save remain on disk. Private browsing does not make you anonymous to websites, your network or your provider. OS-level artifacts and website fingerprinting are outside this feature’s guarantees.

Automatic update checks are off until you enable them. Manual checks and opted-in automatic checks request public release metadata from GitHub; GitHub receives the normal connection information, including your IP address. No account token, browsing history, cookies or website credentials are included. There is no automatic replacement or execution of downloaded apps. Use **Alcove → Check for Updates…** to see release notes and the installer link.

Settings includes profile-specific history deletion and website-data clearing. Clearing website data signs you out and closes that profile’s tabs, pins, Favorites and Quick Browse pages across its windows; other profiles, bookmarks and downloaded files remain. Deleted data may still exist in backups or filesystem snapshots; Alcove does not promise secure erasure.

Camera/microphone requests ask for permission for the focused HTTPS origin. macOS permission controls also apply. Location, web notifications and full site-permission management are not supported in this preview. WebKit’s normal TLS validation is retained; there is no certificate-error bypass.

See [SECURITY.md](SECURITY.md) for the threat model and reporting. This release has received source review and limited automated/manual verification, not an independent security audit.

Site icons are requested only from the already visited website’s origin, rasterized within WebKit, and kept in this window’s memory. No external favicon lookup service is used.

## First-prototype migration

The first `Browser.app` prototype used unsandboxed, plaintext `session.json`. Its data is not silently read from outside the sandbox. To bring those tabs into Alcove, choose **File → Import Preview Session…**, then select `~/Library/Application Support/OpenBrowser/session.json`. Spaces are added without replacing current tabs. The original JSON is kept and contains readable URLs; manage that original file yourself.

The first profile-enabled launch migrates encrypted `session.sealed` into `session-v2.sealed` using the existing Keychain key. The old file is retained, encrypted and untouched, as a migration/recovery copy. Older previews continue using that copy and cannot overwrite the new profile registry. Changes made in an older preview after migration are not automatically merged. Quick Browse advances the document to format 3 in the same `session-v2.sealed` file; 0.5 readers refuse that newer format without rewriting it. Unknown future metadata versions stay locked and are never rewritten. The retained copy may contain older URLs and history; deleting current history does not erase this copy or system backups.

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

This runs core/store/profile/window-lifecycle/real-website/appearance/update checks, compiles both architectures, combines the executable, signs it ad hoc with sandbox/hardened-runtime entitlements, verifies signatures/architectures, generates an icon, and produces a ZIP and SHA256SUMS.txt, plus a DMG when disk-image services are available under `dist/`. It does not publish anything or use paid signing credentials. CI checks every push/PR; matching preview tags package and publish verified ZIP and DMG downloads. See [RELEASE.md](RELEASE.md).

## Shortcuts

| Shortcut | Action |
| --- | --- |
| Command-L / Command-T | Address bar / new tab (new quick page in a compact window) |
| Command-W / Command-Shift-T | Close / reopen tab |
| Command-Shift-N | New private window |
| Command-N | Open main window |
| Command-Option-N | New Quick Browse |
| Command-Control-N | New Space |
| Command-F | Find in page |
| Command-D | Bookmark page |
| Command-Shift-B | Library |
| Command-comma | Settings |
| Command-Shift-comma | Customize appearance |
| Command-R | Reload |
| Command-S | Toggle sidebar |
| Command-Shift-P | Pin/unpin |
| Command-Shift-D | Split view |
| Control-Tab / Control-Shift-Tab | Next / previous tab |
| Command-Option-Right / Left | Next / previous Space |
| Shift-click a link | Peek preview |
| Command-plus / Command-minus / Command-0 | Zoom in / out / reset |
| Command-[ / Command-] | Back / forward |

## Still needed before a stable release

Broader website/login/media/download compatibility testing; accessibility and keyboard polish; permission revocation UI; authenticated update signing; password-manager integration; independent security review; performance/energy benchmarks; phishing/malware protection strategy; full bookmark import/export, broader profile lifecycle testing and multiple normal windows. WebKit does not automatically make Chrome extensions compatible.

Arc-inspired next steps include more gesture/animation fidelity, site search, richer routing rules, Boosts and Easels/capture. Quick Browse supplies the Little Arc-style external-link workflow. Favorites, drag organization and Shift-click Peek are implemented; full Arc parity is not claimed. Sync and AI features are intentionally outside the preview. No Safari-equivalent speed or complete-security claim is made.

Optional tab suspension can stop background media and lose unsaved page state. Optional archive preserves pinned tabs and each Space’s selected tab, and offers restore from the Library. Those Space-tab controls require deliberate opt-in; Quick Browse has its own default six-hour policy and can be turned Off.

## License

MIT for this repository’s code. Apple frameworks retain their own terms.
