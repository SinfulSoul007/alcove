# Embedded WebKit work in progress

The original full uBlock Origin 1.76.4 passed the unchanged ZIP and CRX witness in [run 45539376893](https://github.com/SinfulSoul007/alcove/actions/runs/45539376893), with 24 native assertions and successful owned cleanup. The independently read-back result qualifies that test executable and pinned engine. **The ordinary downloadable app does not embed this engine yet.** Public 0.20 remains a system-WebKit preview.

## Verified packaging components

`scripts/engine/qualified-runtime.json` pins wrapper `1fc08bd2013efe318f3d7b7914a24dcf9af07916`, WebKit source `26695efdefc6076049ec50713a2c4e54b90b4d47` and source artifact `14965369072`. The input verifier freshly extracted and authenticated the exact original archive, all 18 patches, 27 roots, 10,568 members, link graph and three framework hashes. It preserves existing destinations and publishes no partially verified extraction.

All 21 actual regular Mach-O images were inspected. Developer-environment command removal was tested in memory with unchanged section bytes/offsets, platform fields and all other commands; the retained engine was untouched. The layout/dependency planner mapped all 10,568 members and all 21 images, with 26 owned dependency rewrites and seven explicit XPC alias replacements planned. The complete graph was copied into its normalized layout and all original file bytes/modes verified again after moving the prepared tree. The seven development XPC aliases now have actual service bundles at the framework lookup locations; an explicit resource alias and empty canonical framework directory preserve the other required lookup paths. Dynamic-library metadata relocation, signing and service execution are still required; this prepared tree is not a runnable app package.

The complete focused Python suite passes 32 tests, including malformed metadata, section/code/data/platform changes, unsafe or omitted dependencies, duplicate IDs, escaping members, the canonical optional input link, atomic staged output, bad service aliases, resource tampering/omission, unexpected extra output and verification after relocation. Test-only qualification journal derivation passes 14 actual Foundation checks and both ordinary and qualification helper variants typecheck without warnings. Qualification journals derive from an explicit run UUID under the app's writable container cache, rather than writing beside the executable in a signed bundle. Actual packaged sandbox recovery remains to be run.

## Metadata-relocation checkpoint

The focused component suite now passes45 tests with zero failures. Nine new
verifier tests first failed because relocation verification was absent; four
real-tool/filesystem tests then exposed the missing copy operation. The
implemented operation preserves authenticated input bytes/modes, rejects an
existing destination, uses Apple tooling on a temporary copy, verifies exact
allowed changes and atomically publishes a new file without replacement.
Insufficient header space and bad input publish nothing.

All21 actual images from the authenticated engine were independently relocated
through this operation. Every code/data section byte and offset, platform/OS
metadata, dylib version and unrelated command remains unchanged; only planned
install names/dependencies/rpaths and approved developer-search metadata changed.
Input files retain their original hashes. This qualifies these static image
copies only. Complete transformed-bundle assembly, signing, resources/notices,
native service execution and original-uBlock/ordinary-app/package gates remain
open. The original copied signatures are not valid after relocation and are not
used as native qualification evidence. See [component usage](../scripts/engine/README.md).

## Complete relocated engine tree

The component suite passes53 tests after complete-tree assembly and verification
were added. The new cases exercise full resource/service preservation, a moved
tree, unmapped dependencies, staging failure cleanup, existing destinations,
changed input/output/resources, unexpected code and missing/duplicated proofs.

The actual authenticated10,568-member engine graph was assembled with all21
metadata-relocated images. Full resource provenance and relative dependency
closure passed. The resulting tree was moved and independently verified again
against the immutable input; every original input member/hash remained unchanged.
This is a complete prepared engine fragment, without an app entry point or valid
post-transform signatures. `nativeAppQualified` and `ordinaryAppQualified` remain
false, and `signingPending` remains true. It is not a downloadable browser.

The dedicated VM's current public identity inventory reports zero valid
code-signing identities and no full Xcode installation. No private key was read,
exported or used. Signing/native service execution, licensing/source notices,
the frozen original-uBlock witness, ordinary app integration and distribution
qualification remain open.

## Unsealed frozen-witness app template

The component suite passes73 tests with the actual pinned vendor archives.
The frozen witness retains SHA-256
`2155d8b27904ca8105f3debee0d3f30242fa387c13d39d0072ed3fcdfea7b725`.
It compiles with the exact app-source baselineefeedfd8 and the scoped ownership
journal helpers; no test assertion or vendor code was edited. BrowserCore is
statically linked, and the complete engine plus original ZIP/CRX are packaged
with the qualification bundle ID and the26.5 deployment floor.

The actual optimized entry compiled with selected SDK metadata26.5, linked
SDK27.0.0 and deployment26.5. A too-strict initial SDK-equality guard was corrected
to preserve the actual SDK label while requiring the deployment floor and a
compatible SDK. Apple tooling's automatic rewrite of linker ad-hoc signatures
then triggered the strict file-length guard. The entry is now linked unsealed,
with normal reserved header space, and all code/data/platform derivation checks
remain intact. The prepared app was moved and reverified successfully, including
through the terminal command. It has never been launched.

This is static template evidence only. Its results explicitly retain native,
ordinary-app and sandbox qualification as false, with signing pending. The six
public app entitlements are signing intent. A legitimate identity, per-role
public signing policy, source/license notices, actual signed sandbox/service
execution, the unchanged native full-uBlock proof and cleanup/recovery remain
required. Public tags, updater compatibility and the default browser are unchanged.

## Concrete signing gate

VM `job-956-engine-library-validation` built an owned C app and bundled C library. Both were ad hoc signed with Hardened Runtime, and the app retained exactly the existing six sandbox entitlements. `codesign --verify --deep --strict` passed. Launch with developer variables absent failed before `main` (exit -6): dyld rejected the bundled library because the process and mapped non-platform image had different Team IDs. No library-validation exception, sandbox removal or private entitlement was added.

The available code-signing identity check reports zero valid identities. Apple's [library-validation documentation](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.disable-library-validation) explains the Apple-or-matching-Team requirement. A legitimate suitable signing identity is therefore a native qualification prerequisite for this package under the preserved policy. Static package preparation can continue; it must not be represented as a runnable or publicly qualified engine app.

The current source engine also requires arm64 and macOS 26.5 according to every actual image's minimum-OS metadata. Lowering a plist or binary minimum would not establish compatibility. Preserve the existing macOS 14+/Intel system-WebKit path and retain wider engine portability in the full objective.

## Remaining gates

Complete the recorded member layout and relative dependency closure, preserve WebKit service identities/resources/sandbox profiles, derive and verify allowed metadata changes, include applicable source/notices, sign with a suitable matching identity, then run the frozen full-uBlock witness in the genuinely sandboxed self-contained app. Next verify the ordinary optimized entry point and its real manager/install/permission/dashboard/filtering/disable/relaunch/removal behavior after relocation and installation. Keep test-app, ordinary-app, downloadable-package and public-update results separate.

No engine-capability/private-support/public-release claim is widened by this work. Reader, Arc feature parity, live visuals/accessibility, media/fullscreen/PiP, broader extensions/sites and hardware/performance/security checks remain part of the active browser goal. The implementation plan is `docs/superpowers/plans/2026-11-24-embedded-webkit.md`.
