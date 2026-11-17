# Unsigned preview release process

Alcove is available without a paid Apple Developer membership as a downloadable ad hoc signed app. This does not provide trusted Developer ID signing or notarization. Gatekeeper may block downloads; never ask testers to disable security protections.

1. Review the source changes and unresolved security/compatibility limitations.
2. Run `./scripts/package.sh`. It runs core/store/appearance/update checks, builds Apple Silicon and Intel slices, verifies the combined executable and signature, and creates `dist/Alcove-VERSION-universal-unsigned-preview.zip`, `SHA256SUMS.txt`, and a DMG when disk-image services are available. The source version in `scripts/Info.plist` determines each filename. Local packaging tolerates environments without disk-image services; CI and public release jobs require a verified, mountable DMG.
3. Inspect the actual app with `codesign --verify --deep --strict build/universal/Alcove.app`, `codesign -d --entitlements - build/universal/Alcove.app`, and `lipo -archs build/universal/Alcove.app/Contents/MacOS/Alcove`.
4. Launch the combined app locally and exercise normal browsing, private mode, find, library and session restoration. Intel compilation is not an Intel hardware test; record actual hardware tested. Also test a quarantined download and the minimum supported OS before recommending broad use.
5. Set `CFBundleShortVersionString`, increment `CFBundleVersion`, and set `AlcoveReleaseTag` in `scripts/Info.plist` before committing. For example, pair version `0.10.0` with tag `v0.10.0-preview.1`. Push the reviewed commit to main or the matching `preview/VERSION` branch, then push the matching tag after its CI finishes. The release workflow checks the tag and reuses the exact successful CI package when available. Otherwise it builds and tests both slices from the tag. Either path verifies installer checksums, application signatures and the mounted DMG before publication. Only the publication job needs release write access. Keep published tags and their assets intact on reruns.
6. Update the workflow release notes for the exact source, including metadata migrations and extension/engine restrictions. Verify the published assets by downloading them and checking their hashes and app signatures again. Keep the release body candid about data security limits, incomplete features, test coverage and Gatekeeper restrictions. Never claim the app is “secure” solely because it is encrypted or notarized.

The build never includes source-user sessions, browsing history or Keychain material. ZIP verification checks the app layout and executable mode. DMG verification checks its integrity. The icon is generated locally from code; there are no remote release-build dependencies.

## Ongoing updates

Every push and pull request runs `.github/workflows/ci.yml` and retains verified preview artifacts. In-app checks query public releases, compare semantic versions, filter stable and preview channels, and prefer the universal DMG. Automatic checks are opt-in and throttled to one attempt per day. Use **Verify Download** to compare a chosen file with the offered installer’s checksum. Download and install updates manually.

The manual `package-dmg.yml` workflow remains available to add a DMG to an older ZIP-only preview. New releases use the tag workflow so publication follows mounted-image verification.

## Release manifest signing

To enable authenticated update offers, set `AlcoveUpdateSigningPublicKey` in `scripts/Info.plist` to the canonical base64 encoding of the 32-byte Ed25519 public key. Preserve an offline backup of the private key. Put the base64 encoding of its 32 raw private key bytes in the `ALCOVE_UPDATE_SIGNING_KEY` environment secret for `alcove-release-signing`. Restrict that environment to reviewed release tags and restrict who can create those tags. Keep the private key outside source control and test the tagged transition before distributing the trust anchor.

With a public key pinned, publishing requires the corresponding private key and adds `Alcove-update-manifest-v1.json` and `Alcove-update-manifest-v1.sig` to the release. Alcove uses the pinned key to verify the manifest before showing the update. The manifest signature covers the commit, tag, installer lengths and checksums. Apple Gatekeeper still evaluates each app bundle.

## Future trusted releases

A Developer ID Application certificate, supported signing environment and Apple notarization are needed for the normal trusted direct-distribution path. Then replace ad hoc signing with Developer ID signing, retain Hardened Runtime, notarize with `notarytool`, staple the ticket and verify Gatekeeper acceptance on the actual download. Keep Apple signing credentials in a secure, narrowly scoped environment outside the repository.
