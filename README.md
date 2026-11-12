# Alcove

A native, open-source WebKit browser for Mac, inspired by Arc’s sidebar, Spaces and focused browsing workflow. Independent project; no Arc code, trademarks or assets are included.

**Status: experimental, unsigned preview.** Useful for testing, not yet recommended as your primary browser. No account or subscription is required. macOS 14 or newer; Apple Silicon and Intel.

## Download

Latest preview: [Download 0.8.0 DMG](https://github.com/SinfulSoul007/alcove/releases/download/v0.8.0-preview.1/Alcove-0.8.0-universal-unsigned-preview.dmg) · [ZIP](https://github.com/SinfulSoul007/alcove/releases/download/v0.8.0-preview.1/Alcove-0.8.0-universal-unsigned-preview.zip).

Download the universal DMG or ZIP from [GitHub Releases](https://github.com/SinfulSoul007/alcove/releases). The app is self-contained: you do **not** need Xcode or developer tools to use a download. Open the DMG and drag **Alcove.app** to Applications, or unzip it and move the app there.

**The preview is ad hoc signed, not Developer ID signed or notarized by Apple.** Gatekeeper may warn or block it. Do not disable Gatekeeper or other system protections to run it. If macOS blocks this preview, build from source or wait for a notarized release. Published SHA-256 checksums identify the release files; they are not an independent security certification.

## Features

- Compact, resizable Arc-style sidebar with Favorites tiles, pinned tabs/folders, Today and named Spaces.
- Twelve per-Space themes, custom gradients/accent colors, Space icons and a live appearance preview.
- Tab density, text size, corner rounding, responsive Favorite columns, icon/close-button visibility and reduced-motion support.
- A bottom Space dock and delayed collapsed-sidebar edge reveal; sidebar drag width saves on release.
- Themed Spaces overview, rename/icons/reordering, and encrypted Recently Deleted/Undo recovery.
- Responsive startup while Keychain approval waits, with private browsing available immediately.
- Animated, skippable first-launch setup, plus a replayable welcome tour. Existing sessions and private windows skip setup.
- Manual GitHub update checks, stable/preview channels and optional daily checks. Downloads and installation remain explicit actions.
- Favorites, Pinned and Today scroll separately, keeping saved pages visible while you browse daily tabs. Bookmarking also pins the original page without reloading it.
- Create empty folders from the Pinned header, File menu or command bar. Move tabs into folders using their context menu or drag-and-drop; rename folders or remove them while keeping their tabs pinned. Folder definitions survive relaunch.
- Drag tabs between sections and into folders. Pinned tabs keep their title and saved home URL when closed. ⌘W closes the focused page (or Peek/panel first), then closes an empty window while leaving Alcove running.
- Folders for pinned tabs; right-click a tab to organize it.
- Split view with actions targeted to the clicked pane.
- Keyboard-driven command bar with tab switching, Pin/Favorite commands and no empty tab created on cancellation.
- Shift-click Peek previews in their originating main or compact window, with close and open-in-Space controls.
- Quick Browse compact external-link windows, exact-host profile memory, same-link resurfacing and live page handoff into a Space. Forms, scroll and navigation history survive a same-profile handoff.
- Named profiles with separate website logins/storage, Favorites, bookmarks, history, closed tabs and archives. Multiple Spaces can share a profile.
- Private windows with temporary WebKit storage and no saved session/history.
- Bookmarks, searchable history, closed-tab restore and an archive library.
- Find in page, zoom, back/forward gestures, reload/stop.
- Native printing, PDF export and WebArchive saving, with Quit choices for unfinished output.
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

Quick pages stay independent when their intended Space changes or disappears. Closing the main window stops its native pages and primary Peek while keeping its saved tabs and the same browser store alive for remaining compact windows. Peeks in separate windows preserve their own live state. Command-N reopens the main window; closing the last window disposes its store, and Alcove stays in the menu bar until Quit. There is still only one normal primary window at a time.

Quick pages and their archive are encrypted with their owning profile’s metadata. The default inactivity archive is six hours. Focused/loading pages, active playback/capture and open native sheets are kept; unknown media state is retained for a later check. Archiving closes live state and can discard unsaved forms. Choose **Off** to keep pages open. Use **Library → Archive → Quick Browse** to reopen in a compact window or directly in a matching-profile Space. Private quick records and preferences remain in memory only.

## Page output

**0.6.2** adds **File → Print…** (Command-P), **Export as PDF…** and **Save Page As…** (Command-Shift-S, WebArchive). Command-S still toggles the sidebar. These commands follow the visible split pane, Peek or Quick Browse page and use native print/save dialogs. Accepted exports continue if their source window closes; Quit offers to wait for output, keep browsing or explicitly quit without finishing. A failed save cancels a waiting Quit. The public 0.6.2 preview includes these commands. Native dialog/printer testing remains in progress; see the [verification report](docs/releases/0.6.2-verification.md).

Exported PDF/WebArchive files, printer output and print-system artifacts are outside Alcove's metadata encryption. They can contain sensitive page content and metadata, including from private windows. Saved archives are not yet opened through Alcove's UI, and website print buttons using `window.print()` are not wired to native printing yet. Native dialog/printer testing remains pending.

## Site search

The 0.8 preview includes configured site shortcuts. Type `yt`, `wiki` or `gh` in the command bar or Quick Browse address field, press Tab, then type a query and press Return. Empty Backspace restores the shortcut; the pill's close button leaves site mode and keeps your query. Normal Return behavior stays unchanged until you select a site.

Use **Alcove → Site Search Settings…**, Settings, or the command list to add, edit, disable or remove shortcuts. A search URL uses one `%s` for the query, with complete URL escapes for other literal percent signs. Path templates reject queries that would become dot-only path segments. Matching stays local and sends nothing before submission. Normal profiles share encrypted shortcut settings; searches use the current page's actual profile. Private windows start with presets and keep changes temporary. Editing or removing a selected provider requires selecting it again before submission. Automatic site discovery is still pending.

## Link routing

The 0.8 preview includes **Alcove → Link Routing Settings…** (also Settings → Links, or “Link Preferences”/“Air Traffic Control” in the command list). Add ordered Contains/Equals URL conditions and choose Quick Browse, Most Recent Space or a named Space. The first enabled match wins. The default applies to links from other apps; routing and its test-URL preview stay local. Named Spaces select their own profile; Quick Browse/recent routes retain the source or remembered account. An unavailable matching destination blocks the opening until edited.

Archive restoration follows matching routes, otherwise its original same-profile Space. Opening a Peek within its profile keeps its live page state; changing profiles asks to reload with separate website logins. Cancellation, a changed route/document or a failed metadata write preserves the original preview. Private windows ignore normal link rules. See the [source verification record](docs/goal/link-routing-verification.md) for evidence and remaining native QA.

## Website Boosts

The 0.8 preview includes **Alcove → Website Boosts…**, Settings → Website Boosts, the command “Create Boost”, and **Boost This Site…** in the main and Quick Browse action menus. Each profile keeps its own saved looks for an exact hostname across HTTP, HTTPS and ports. Choose colors, fonts, relative text size, a preset or Shuffle. Appearance choices save immediately; name/site/CSS/JavaScript drafts use **Save Changes** or **Done**. Unsaved drafts survive switching panels, and a Quick Browse editor stays bound to its original profile.

Use **Hide an Element…** to choose page elements without deleting their DOM nodes or reloading a form. **Undo**, individual **Unhide**, and **Unhide All** restore them. **Done** or Escape leaves picker mode; text composition receives Escape first. Styles apply to the main document. Frame contents and shadow roots keep their own styling.

JavaScript requires local approval for its exact code and site. Approval applies to future loads; **Run on This Page** is explicit and runs the saved script once per document. Editing code requires fresh approval. Turning a Boost off stops future runs; reloading may be needed to undo earlier script effects. **Share Appearance → Copy/Paste** transfers local JSON containing styles and hidden-element rules. Imported looks start disabled and contain no JavaScript or approval. Review custom CSS before enabling it: styles can change page behavior and request resources. Private definitions and approvals stay temporary and separate.

Source fixtures cover storage, WebKit effects and owned native control logic. Live control colors, focus, accessibility, animations, Arc fidelity and broad website compatibility remain under verification; offscreen renders do not establish visual perfection.

## Manage Spaces

Choose **Spaces → Manage Spaces…**, use the sidebar’s Space menu, or type **Manage Spaces** in the command bar. The manager shows themed cards with saved tab previews beside the current page. It keeps the current website mounted; card previews do not open extra websites. Use a card’s menu or right-click its sidebar icon to rename, change its icon, move it or delete it. Drag a card’s move handle or a sidebar Space icon to reorder; move controls provide a keyboard alternative. Customize retains name/icon/theme controls, with explicit saving for names.

Deleting a Space moves its saved tabs, pins, folder state and theme to **Recently Deleted**. An Undo action is available immediately, and recovery remains available after relaunch. Profile logins and shared Favorites stay intact. Deletion closes Space-owned pages; unsaved forms and page state cannot be recovered. Restoring preserves the owning profile and repairs identity collisions without replacing existing Spaces. If recovery encounters conflicting Space identities, affected saved link routes stay unavailable until you choose the intended destination in Link Routing Settings. Permanent removal requires confirmation. Clearing a profile’s website data/history also removes its deleted Space recovery copies. Private Space recovery stays in memory and ends with that private session.

Space recovery upgrades metadata to format 4 in the existing encrypted file. Earlier formats migrate without changing the Keychain key. Older readers refuse format 4 instead of dropping recovery records; quit Alcove before replacing its app bundle, and keep using the newer version after migration.

Only one cooperating Alcove process owns a normal metadata directory at a time. A second copy offers **Try Again** and **Open Private Window** without requesting a key or writing the active copy’s session. Ownership releases on shutdown or process exit. Saves also stop if a held lock or data-folder identity changes; a loaded session cannot follow a retargeted folder alias. This coordinates Alcove instances, without claiming protection against unrelated programs continuously rewriting files with your account’s access.

## Privacy and security

Alcove has no analytics, sync server or account service. Sites you visit receive their normal web requests; ordinary web searches go to DuckDuckGo; configured site searches go to the selected site. No remote search suggestions are sent while you type.

Profiles separate website storage and organization within one Mac account; they are not separate user accounts or protection against someone using the unlocked app.

Alcove metadata is encrypted on disk. WebKit manages cookies, caches, website storage and rendering processes separately; they are **not** covered by Alcove’s metadata encryption. Keep macOS current for WebKit security updates. Encryption does not protect against malicious software already running as you or an unlocked, compromised Mac. It is not a substitute for FileVault and OS account security.

Normal metadata is saved to the app’s sandbox Application Support directory, under `OpenBrowser/session-v2.sealed`. On a standard macOS install this is `~/Library/Containers/dev.openbrowser.mac/Data/Library/Application Support/OpenBrowser/session-v2.sealed`. The key stays in Keychain and is not included in downloads, source, or metadata files. Copying this encrypted file to another Mac alone is insufficient to restore it. If the key cannot be read or the file is corrupt, Alcove disables saving rather than overwrite existing data. Startup shows a responsive loading window while Keychain work runs in the background. macOS may still ask for Keychain approval for changed unsigned code; an explicit Unlock action retries failed access, and private browsing stays available. Local saving remains visibly paused until recovery succeeds.

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

The developing sidebar checkpoint has [verification notes](docs/releases/0.9.0-sidebar-preview-verification.md).

## Build from source

The developing 0.9 source upgrades metadata to format 5 for extension identities and permissions. Public 0.8 downloads use format 4 and cannot read format 5. Keep a backup and quit Alcove before replacing its bundle; extension installation and hosting are still in development.

See the [native extension development checkpoint](docs/releases/0.9.0-extension-development.md) for tested private-window, permission, action and command/menu boundaries and the remaining integration work.

Install Apple Command Line Tools or Xcode with a modern macOS SDK that includes WebExtension APIs (macOS 15.4 or newer), then:

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

Arc-inspired next steps include more gesture/animation fidelity, automatic site-search discovery, live routing/gesture fidelity, Boosts and Easels/capture. Quick Browse supplies the Little Arc-style external-link workflow. Favorites, drag organization and Shift-click Peek are implemented; full Arc parity is not claimed. Encrypted sync and assisted workflows remain unimplemented parts of the broader browser goal. No Safari-equivalent speed or complete-security claim is made.

Optional tab suspension can stop background media and lose unsaved page state. Optional archive preserves pinned tabs and each Space’s selected tab, and offers restore from the Library. Those Space-tab controls require deliberate opt-in; Quick Browse has its own default six-hour policy and can be turned Off.

## License

MIT for this repository’s code. Apple frameworks retain their own terms.
