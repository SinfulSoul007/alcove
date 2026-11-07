# Security policy

Alcove 0.2 is an unsigned experimental preview, not an independently audited or stable browser. No release is currently represented as suitable for all sensitive browsing. Keep macOS updated: Alcove uses system WebKit.

## Boundaries

- App Sandbox limits host-app access to outbound network connections, user-selected files and user-authorized camera/microphone use. No temporary sandbox exceptions or library-validation/JIT exceptions are requested by the host.
- Hardened Runtime is enabled; signing is ad hoc, not an authenticated Developer ID identity. Apple notarization is absent.
- Normal session/library/preferences are AES-GCM encrypted with a 256-bit Keychain key marked `WhenUnlockedThisDeviceOnly`. Metadata files use mode 0600 in a 0700 directory. Authenticated decryption failure or unavailable Keychain disables saving to preserve data.
- WebKit cookie/cache/website databases are separate from the encrypted metadata and managed by the system framework. We do not claim all on-disk browsing artifacts are encrypted by Alcove.
- Private windows use nonpersistent WebKit storage, do not ask for a metadata key, and never write a session/library. Downloads deliberately saved to a chosen path remain on disk. OS artifacts, swap, screenshots and remote observations are not prevented.
- TLS validation uses WebKit defaults. Release views are not inspectable through Web Inspector. Unsupported external app schemes are blocked rather than silently opened.
- Media permission grants are request-specific, for the focused HTTPS origin, with a user prompt and an origin recheck before granting. No persistent allow-list exists in this preview.
- No passwords are stored by Alcove. There is no analytics, sync service, remote suggestion service or self-update code.

## Recovery and known limitations

Lost Keychain keys make existing metadata unreadable. Do not delete keys to fix startup; preserve both the encrypted file and Keychain state. Keychain may ask for access after locally signed app updates. Stop if the requesting app is not the copy you intended to run. No plaintext fallback is used if encryption fails.

Sandboxed first releases cannot silently read unsandboxed prototype data. Import is an explicit user-selected JSON operation; source JSON remains on disk. Website-data clearing is logical deletion, not a claim of secure physical erasure or removal from backups.

This preview lacks a Safe Browsing service, complete website-permission controls, a password manager, extensions and a signed automatic-update channel. Location and notifications are unsupported. We have not established safety of every complex auth/DRM/WebRTC scenario or benchmarked energy efficiency against Safari. Follow the project’s release notes before updating.

## Reporting

Report vulnerabilities privately through the repository’s GitHub security advisory reporting channel when available. Never include real passwords, cookies, private browsing URLs, Keychain exports or personal data in a public issue. Ordinary non-sensitive bugs may be filed as GitHub issues. No response-time guarantee or bug bounty is offered for this early project.
