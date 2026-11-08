# Unsigned preview release process

Alcove is available without a paid Apple Developer membership as a downloadable ad hoc signed app. This does not provide trusted Developer ID signing or notarization. Gatekeeper may block downloads; never ask testers to disable security protections.

1. Review the source changes and unresolved security/compatibility limitations.
2. Run `./scripts/package.sh`. It runs core/store/appearance/update checks, builds Apple Silicon and Intel slices, verifies the combined executable and signature, and creates `dist/Alcove-0.5.0-universal-unsigned-preview.zip`, `SHA256SUMS.txt`, and a DMG when disk-image services are available. The source version in `scripts/Info.plist` determines each filename. Local packaging tolerates environments without disk-image services; CI and public release jobs require a verified, mountable DMG.
3. Inspect the actual app with `codesign --verify --deep --strict build/universal/Alcove.app`, `codesign -d --entitlements - build/universal/Alcove.app`, and `lipo -archs build/universal/Alcove.app/Contents/MacOS/Alcove`.
4. Launch the combined app locally and exercise normal browsing, private mode, find, library and session restoration. Intel compilation is not an Intel hardware test; record actual hardware tested. Also test a quarantined download and the minimum supported OS before recommending broad use.
5. Set `CFBundleShortVersionString`, increment `CFBundleVersion`, and set `AlcoveReleaseTag` in `scripts/Info.plist` before committing. For example, version `0.5.0` and tag `v0.5.0-preview.1`. Push the reviewed commit, then the matching tag. `.github/workflows/release-preview.yml` rejects mismatched tags, rebuilds/tests both slices, verifies checksums/signatures/ZIP and mounted DMG contents, then publishes a GitHub **prerelease** with both installers and checksums. The publication job has write access; the build job does not. Existing releases are not overwritten on reruns. Avoid the stable/latest designation.
6. Keep the release body candid about data security limits, incomplete features, test coverage and Gatekeeper restrictions. Never claim the app is “secure” solely because it is encrypted or notarized.

The build never includes source-user sessions, browsing history or Keychain material. ZIP verification checks the app layout and executable mode. DMG verification checks its integrity. The icon is generated locally from code; there are no remote release-build dependencies.

## Ongoing updates

Every push and pull request runs `.github/workflows/ci.yml` and retains verified preview artifacts. Preview tags trigger publication without paid signing credentials. In-app checks query public releases, compare semantic versions, filter stable/preview channels and prefer the universal DMG. Automatic checks are opt-in, throttled to one attempt per day, and checked while the app remains open or returns to the foreground. Updates are downloaded and installed only at the user's choice; no app is silently replaced. This is release discovery and repeatable packaging, not an authenticated automatic installer.

The manual `package-dmg.yml` workflow remains available to add a DMG to an older ZIP-only preview. New releases use the tag workflow so publication follows mounted-image verification.

## Future trusted releases

A Developer ID Application certificate, supported signing environment and Apple notarization are needed for the normal trusted direct-distribution path. Then replace ad hoc signing with Developer ID signing, retain Hardened Runtime, notarize with `notarytool`, staple the ticket and verify Gatekeeper acceptance on the actual download. Keep signing credentials in a secure, narrowly scoped environment, outside the repository. Establish signed update delivery separately. No future signing credentials are requested or stored by these scripts.
