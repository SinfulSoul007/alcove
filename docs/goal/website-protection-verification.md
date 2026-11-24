# Website protection candidate verification

This records the local website-protection increment for the 0.20.0 preview candidate. It does not complete the full browser goal. Public 0.19.2 downloads remain unchanged until a new tagged package is verified and published.

## Native evidence

The implementation uses the bundled, validated PhishDestroy Primary domain catalog. Owned loopback endpoints replace threat sites in every navigation test. No browsing-address lookup service is enabled.

- Core classifier: 70 checks, zero failures; resource/provenance tooling: 7 checks, zero failures.
- Native request characterization and warning controls: 50 checks, zero failures, including original POST bodies, frames, redirects and navigation downloads.
- Nearby extension navigation: 23 checks; extension surfaces: 24 checks; Quick Browse: 27 checks; ticket lifecycle: 12 checks, all passing in their recorded runs.
- Exact `ea926a4` native witness: 34 checks, zero failures. It added real `browser.windows.create` normal and popup windows, requesting-profile/service inheritance, held request counts, cancellation preserving forms, one-request continuation, and native window closure revoking retained controls. Both owned cleanup journals completed.

The fresh whole-branch review of `c4c89fc..ea926a4` found two Important issues and one Minor issue. An owned native reproduction produced 38 checks with exactly four failures: a retained Continue button approved a replacement warning in the same mounted pane; a normal closed-tab record kept its unvisited blocked destination; Quick promotion retained its main-page warning; and it retained the adopted Peek warning. All other checks and both cleanup journals passed.

The material fix pass gives each displayed warning revision its own immutable button actions and disables detached controls. Durable Quick promotion snapshots the committed address before saving, then cancels its pending decision only after persistence succeeds. Adopting its Peek cancels that pending decision too. Normal tab closure snapshots the committed page from its actual presentation owner before recording Reopen Closed Tab state.

The resulting native witness passes 39 checks with zero failures. Its additional failure-injection control confirms that a failed Quick promotion preserves both original warning tickets, the Quick page and the prior ciphertext; unlocking with the owned test key preserves those warnings. The fixture releases its privileged extension-options page before requesting profile erasure. All temporary windows, website stores and extension controllers are cleaned up. This expanded witness is now `scripts/WebsiteProtectionSurfaceChecks.swift` and runs in the normal full-test pipeline.

Sidebar mouse resizing and keyboard focus-ring restoration were checked live in the VM; the native sidebar suite passed 61 checks. Welcome setup was inspected at its minimum height with all twelve swatches visible. These observations do not establish complete accessibility or Arc visual parity.

## Distribution and open gates

The app remains a macOS 14+ universal, ad hoc signed system-WebKit preview. New candidate metadata is version 0.20.0, build 31, tag `v0.20.0-preview.1`. Full exact-candidate hosted tests, both architecture builds, ZIP verification and mounted-DMG verification must pass before tagging it. Existing published tags and assets must stay intact.

The candidate pins a public update-verification key. The actual publisher script and production verifier passed local owned-file tests for both DMG and ZIP metadata and rejected a different key and modified payload. The GitHub signing environment permits preview tags only. Private-key upload still requires the owner's explicit authorization; no key has been uploaded or copied into Git or the VM. An owner-managed offline backup and an actual signed public update transition remain required before relying on the trust anchor. These signatures do not provide Apple signing or notarization.

The separate experimental JSC build passed its 20 Promise-realm checks and extension API component gates. Its final artifact and all nineteen retained binary hashes were verified on the host and in the VM. However, the unchanged full uBlock Origin ZIP still redirected its dashboard to the background document before test messages; the CRX case was not reached. That engine is not qualified for this release and is not bundled.

The feature does not classify subresources, IP reputation, URL paths, malicious files or page contents. Runtime feed updates and Safari-equivalent detection coverage are deferred. Chrome Web Store discovery/transport are separate existing surfaces. Full uBlock Origin, broad extension compatibility, independent security review, accessibility, real Intel/minimum-OS testing and the remaining full-browser acceptance gates remain open.
