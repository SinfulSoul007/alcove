# Unsigned preview release process

Alcove is available without a paid Apple Developer membership as a downloadable ad hoc signed app. This does not provide trusted Developer ID signing or notarization. Gatekeeper may block downloads; never ask testers to disable security protections.

1. Review the source changes and unresolved security/compatibility limitations.
2. Run `./scripts/package.sh`. It runs core/store checks, builds Apple Silicon and Intel slices, verifies the combined executable and signature, and creates `dist/Alcove-0.2.0-universal-unsigned-preview.zip`, `SHA256SUMS.txt`, and a DMG when disk-image services are available. This environment cannot create disk-image devices, so the first downloadable release uses ZIP.
3. Inspect the actual app with `codesign --verify --deep --strict build/universal/Alcove.app`, `codesign -d --entitlements - build/universal/Alcove.app`, and `lipo -archs build/universal/Alcove.app/Contents/MacOS/Alcove`.
4. Launch the combined app locally and exercise normal browsing, private mode, find, library and session restoration. Intel compilation is not an Intel hardware test; record actual hardware tested. Also test a quarantined download and the minimum supported OS before recommending broad use.
5. Commit the reviewed source, then publish a GitHub **prerelease**, explicitly labelled **unsigned and not notarized**. Upload ZIP, DMG and checksums. Avoid the stable/latest designation.
6. Keep the release body candid about data security limits, incomplete features, test coverage and Gatekeeper restrictions. Never claim the app is “secure” solely because it is encrypted or notarized.

The build never includes source-user sessions, browsing history or Keychain material. ZIP verification checks the app layout and executable mode. DMG verification checks its integrity. The icon is generated locally from code; there are no remote release-build dependencies.

## Future trusted releases

A Developer ID Application certificate, supported signing environment and Apple notarization are needed for the normal trusted direct-distribution path. Then replace ad hoc signing with Developer ID signing, retain Hardened Runtime, notarize with `notarytool`, staple the ticket and verify Gatekeeper acceptance on the actual download. Keep signing credentials in a secure, narrowly scoped environment, outside the repository. Establish signed update delivery separately. No future signing credentials are requested or stored by these scripts.
