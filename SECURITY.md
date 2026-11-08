# Security policy

Alcove is an unsigned experimental preview, not an independently audited or stable browser. No release is currently represented as suitable for all sensitive browsing. Keep macOS updated: Alcove uses system WebKit.

## Boundaries

- App Sandbox limits host-app access to outbound network connections, user-selected files and user-authorized camera/microphone use. No temporary sandbox exceptions or library-validation/JIT exceptions are requested by the host.
- Hardened Runtime is enabled; signing is ad hoc, not an authenticated Developer ID identity. Apple notarization is absent.
- Normal session/library/preferences are AES-GCM encrypted with a 256-bit Keychain key marked `WhenUnlockedThisDeviceOnly`. Metadata files use mode 0600 in a 0700 directory. Authenticated decryption failure or unavailable Keychain disables saving to preserve data.
- WebKit cookie/cache/website databases are separate from the encrypted metadata and managed by the system framework. We do not claim all on-disk browsing artifacts are encrypted by Alcove.
- Named profiles use stable macOS 14+ WebKit data-store identifiers; the default profile retains the pre-profile default store. Profile registry and per-profile library records are encrypted with the normal metadata. Cross-profile page moves recreate views without copying cookies.
- Persistent profile transitions save metadata before replacing live pages. Pending deletion/data-clear markers survive interruption, block browsing with that store, and support retry. Per-profile operations are coordinated across window closure/reopening.
- Private windows use nonpersistent WebKit storage, do not ask for a metadata key, and never write a session/library. Downloads deliberately saved to a chosen path remain on disk. OS artifacts, swap, screenshots and remote observations are not prevented.
- TLS validation uses WebKit defaults. Release views are not inspectable through Web Inspector. Unsupported external app schemes are blocked rather than silently opened.
- Quick Browse records and exact-host profile choices are encrypted in normal metadata. One normal writer is leased by primary/compact windows; private owners remain independent and ephemeral. Destructive quick transitions persist before native teardown. Auto-archive keeps focused/loading/capturing/playing pages and native sheets, with stale/unknown SDK replies unable to close a changed page.
- Media permission grants are request-specific, for the foreground primary/compact/Peek HTTPS origin, with a user prompt and ownership/origin/focus rechecks before granting. No persistent allow-list exists in this preview.
- Shift-click Peek uses its originating page’s captured profile or temporary private store. Each primary-window or quick-page context owns its own ephemeral Peek. Closing that window or quick page stops its preview; opening a Peek in another window does not discard it. Closing the primary window tears down its native pages while a surviving quick lease keeps the metadata writer alive. Same-profile promotion keeps its live page; cross-profile handoff requires a reload. Same-origin favicon data stays in memory; layout preferences such as sidebar width are ordinary local defaults.
- No passwords are stored by Alcove. There is no analytics, sync service or remote suggestion service. Update checks are manual or opt-in, use an ephemeral credential-free GitHub metadata request, validate release version/asset URLs, and never install or launch an update. Published checksums do not authenticate the developer.

## Recovery and known limitations

Lost Keychain keys make existing metadata unreadable. Do not delete keys to fix startup; preserve both the encrypted file and Keychain state. Startup uses a noninteractive authentication context; the app shows a saving-paused state if the key cannot be unlocked. The explicit Unlock action may ask for Keychain access after locally signed app updates. Stop if the requesting app is not the copy you intended to run. No plaintext fallback is used if encryption fails. The key service is namespaced by bundle identity so isolated review apps do not request the production app’s key.

Sandboxed first releases cannot silently read unsandboxed prototype data. Import is an explicit user-selected JSON operation; source JSON remains on disk. Website-data clearing is logical deletion, not a claim of secure physical erasure or removal from backups.

Profiles are not an access-control boundary between people using the same unlocked Mac account. Profile-enabled metadata uses `session-v2.sealed`; Quick Browse advances the document format to 3 within that compatibility filename. A 0.5 reader rejects format 3 before changing its data. Encrypted `session.sealed` is retained unchanged for migration/recovery, so older previews cannot overwrite the new registry. Changes in an older preview are not merged into the new file. Unsupported future format versions disable saving before publishing their data. Clearing current history does not erase the retained migration copy, filesystem snapshots or backups.

This preview lacks a Safe Browsing service, complete website-permission controls, a password manager, extensions and a signed automatic-update channel. Location and notifications are unsupported. We have not established safety of every complex auth/DRM/WebRTC scenario or benchmarked energy efficiency against Safari. Follow the project’s release notes before updating.

## Reporting

Report vulnerabilities privately through the repository’s GitHub security advisory reporting channel when available. Never include real passwords, cookies, private browsing URLs, Keychain exports or personal data in a public issue. Ordinary non-sensitive bugs may be filed as GitHub issues. No response-time guarantee or bug bounty is offered for this early project.
