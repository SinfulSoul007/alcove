# Alcove public preview

User intent: deliver a downloadable, native Mac browser with useful Arc-style workflows and responsible handling of browsing data. The user has no Apple Developer membership. Existing authorization is to build directly in Programming/browser, with source on GitHub.

Approach: keep the native SwiftUI/AppKit + system WebKit architecture. Produce an honestly labelled unsigned preview for GitHub Releases; defer notarization until a Developer ID is available. Alternative: wait for paid signing (unnecessary for preview testing); rewrite on Chromium (contradicts requested engine).

Goals for this increment: Alcove branding; a ZIP/DMG people can install without developer tools; private windows using nonpersistent WebKit storage and no metadata writes; encrypted local session/history/bookmark metadata with a Keychain key; no silent overwrite on decrypt failure; website camera/mic prompts, file-upload panel, release inspection disabled; find, zoom, reopen closed tabs, bookmarks/history/download library; pinned folders and opt-in auto-archive of old unpinned tabs. Existing Spaces remain tab collections sharing persistent website storage, not isolated login profiles.

Constraints: macOS 14+, no package dependencies, preserve existing sessions through migration, no certificate bypass, no claim of complete security or Safari-equivalent speed. Keep default-profile data local, disable app analytics, document that websites and the chosen search service receive requests. Private browsing cannot hide activity from websites or the network, and saved downloads remain on disk.

Security boundaries: OS/WebKit own website storage and rendering security; CryptoKit AES-GCM protects Alcove metadata at rest, with a Keychain key, not against malicious software running as the user. Sandbox the app with minimal network, user-selected-file, camera and microphone entitlements and verify installed behavior. Release signing is ad hoc, not trusted Developer ID. Packaging is not a security audit.

Non-goals for this increment: password manager, Chrome extension compatibility, sync, isolated profiles, full Arc parity, signed auto-updates, anti-phishing service, and a stable release endorsement. Track these explicitly as remaining work. Memory eviction is opt-in because it can discard page state.

Validation: core behavioral tests, real encrypted-file tests, private-store persistence tests, compile both architectures where available, executable package smoke checks, manual UI navigation/find/library/private-window/split/session restoration. Fresh source review before publication. GitHub Release must remain marked prerelease and visibly unsigned.
