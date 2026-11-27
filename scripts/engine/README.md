# Embedded-engine packaging components

This development checkpoint authenticates the pinned engine input, stages its
complete bundle layout, plans relative dependencies and relocates individual
image copies or the complete engine tree, and builds an unsealed qualification
app template. Signing and native app qualification remain pending. The ordinary app
and public downloads continue to use system WebKit.

Run the component suite from the repository root:

```sh
python3 -B -m unittest discover -s scripts/engine -p 'test_*.py' -v
```

The genuine-archive qualification cases require the pinned original ZIP and CRX
inputs. Include them with:

```sh
ALCOVE_QUALIFICATION_ASSETS=/absolute/path/to/vendor-archives \
  python3 -B -m unittest discover -s scripts/engine -p 'test_*.py' -v
```

Those archive cases are explicitly skipped when their inputs are absent. No
vendor archives are committed or automatically downloaded by the tests.

The Apple-tool cases require macOS and `install_name_tool`. They exercise real
metadata updates, including rejection when new load commands do not fit in the
existing header space. No fixture is loaded or executed.

The component sequence is:

1. `verified_input.verify_and_extract` authenticates the source contract,
   archive, members, links, build manifest and framework hashes. Retain this
   immutable input and its receipts.
2. `package_candidate.prepare_runtime_layout` stages the complete engine graph
   and verifies resource bytes, file modes, service aliases and confined links.
   Its receipt and `verify_layout_copy` also support a moved output directory.
3. `bundle_layout.plan_relocations` derives the full image dependency map from
   the authenticated inventory. Engine dependencies become bundle-relative;
   actual system dependencies retain their system paths.
4. `image_relocation.relocate_image_copy(source, destination, plan,
   expected_input_sha256)` writes a **new** image copy, uses Apple tooling for
   install names/dependencies/rpaths, and verifies the result before publishing
   that file. The expected digest comes from the authenticated input receipt.
   Existing output is preserved; tool failure and insufficient header space
   publish no image. The source bytes and mode remain unchanged.

For the complete graph, use
`package_candidate.prepare_relocated_runtime_layout(authenticated_runtime, new_destination)`.
It stages every member/resource/service, computes the full dependency map,
relocates all image copies, checks their derivations, and verifies the whole
tree before publishing the prepared engine fragment. Failed staging publishes
no destination. Input remains immutable.

Reverify a prepared or moved tree with
`package_candidate.verify_relocated_runtime_layout(destination, receipt, authenticated_runtime)`.
Keep the original authenticated runtime in the build workspace as the independent
reference; it is not copied into the app. Verification recomputes the image map
and exact derivations, checks resource bytes/modes and the complete member/link
inventory, rejects missing/duplicate image proofs, and resolves every owned load
and loader search path within the bundle. An output's self-reported file hashes
alone do not establish source provenance.

The relocation verifier requires unchanged code/data section bytes and offsets,
platform/minimum-OS metadata, dylib versions and unrelated load commands. Only
the planned names/search paths and approved developer-search command removal
are accepted. Its result always has `nativeAppQualified: false` and
`ordinaryAppQualified: false`.

Metadata changes invalidate the copied development signatures. Inside-out
signing, complete post-transform bundle/resource verification, licensing/source
notices, sandboxed service execution and the frozen original-uBlock witness
remain required. Signing must preserve Hardened Runtime, library validation and
the established sandbox policy. Native success, the optimized ordinary app and
an installed/downloaded release are separate gates; none follows from these
component checks.

## Frozen qualification app template

`qualification.py` compiles the frozen witness without changing its bytes, using
app source baseline `efeedfd8bf7e64284762bbcaa3bc8ed4a6134ea9` and the scoped
qualification journal helpers. The baseline Git object must be available in the
checkout. It statically links BrowserCore, relocates the entry's engine loads,
and bundles the unchanged uBlock Origin1.76.4 ZIP/CRX as read-only resources.
Only the five specifically named app files may accompany the verified engine
tree; unlisted code and overlapping engine members are rejected.

Use separate new destinations outside the immutable engine/runtime inputs:

```sh
python3 scripts/engine/qualification.py prepare-template \
  --engine-tree /absolute/path/to/relocated-engine \
  --engine-receipt /absolute/path/to/engine-receipt.json \
  --runtime /absolute/path/to/authenticated-runtime \
  --assets /absolute/path/to/vendor-archives \
  --build /absolute/path/to/new-build \
  --app /absolute/path/to/NewQualification.app \
  --manifest /absolute/path/to/new-template-receipt.json

python3 scripts/engine/qualification.py verify-template \
  --engine-receipt /absolute/path/to/engine-receipt.json \
  --runtime /absolute/path/to/authenticated-runtime \
  --assets /absolute/path/to/vendor-archives \
  --entry /absolute/path/to/new-build/original-main \
  --app /absolute/path/to/NewQualification.app \
  --manifest /absolute/path/to/new-template-receipt.json
```

The compiler currently selects SDK metadata26.5 and targets arm64/macOS26.5.
Its receipt separately records the actual linked SDK label (27.0.0 on the tested
toolchain); that label is preserved during relocation. The deployment floor must
remain26.5 and the SDK cannot predate it. The entry is linked unsealed with
reserved load-command space so Apple tooling can relocate it without modifying
code/data or rewriting a temporary linker signature. Final legitimate signing
remains mandatory before execution.

These commands compile, assemble and statically verify; they never launch or
sign the app. Successful output retains `nativeAppQualified: false`,
`ordinaryAppQualified: false`, `sandboxQualified: false` and
`signingPending: true`. The exact six app entitlements are recorded as signing
intent, not claimed as effective sandboxing. Public per-role signing policy,
source/license notices, the actual sandboxed frozen witness, cleanup/recovery,
ordinary-app integration and installed/public package gates remain open.

Apple documents [the matching-Team library-validation requirement](https://developer.apple.com/library/archive/documentation/Security/Conceptual/CodeSigningGuide/Procedures/Procedures.html)
and [free Xcode Personal Teams](https://developer.apple.com/help/account/basics/about-your-developer-account/).
A legitimate development identity is a possible local-test route, not evidence
that this engine runs, and not a replacement for public distribution
qualification. Developer ID/notarization and public shipping have separate
[Apple requirements](https://developer.apple.com/developer-id/).

## Corresponding source and notice preparation

Use a separate owned bare Git cache containing the complete pinned upstream
revision. These commands read source objects and prepare distribution material;
they do not extract or execute upstream source, build an engine or sign an app.
Git must support `--attr-source` so producer diff attributes can be reproduced.

```sh
git init --bare /owned/upstream-webkit.git
git -C /owned/upstream-webkit.git fetch --depth=1 https://github.com/WebKit/WebKit.git 26695efdefc6076049ec50713a2c4e54b90b4d47

python3 -B scripts/engine/source_archive.py \
  --source-git /owned/upstream-webkit.git \
  --destination /owned/WebKit-source.tar.gz

python3 -B scripts/engine/source_notices.py \
  --archive /owned/WebKit-source.tar.gz \
  --source-git /owned/upstream-webkit.git \
  --contract-checkout /verified/pinned-wrapper \
  --runtime /verified/original/runtime \
  --destination /owned/new-engine-source-package
```

The archive writer streams raw Git blobs. Normal `git archive` can omit files,
substitute text or convert line endings according to attributes; it therefore
cannot be assumed to preserve the complete original Git tree. The independent
verifier authenticates every file, executable bit and symlink target against
the pinned tree, without extracting or following archive links. Bad or missing
members, duplicates, changed bytes/modes and unsupported member types fail
before publication.

The package includes the complete upstream archive, intact notice candidates,
all 18 unchanged patches, their producer order, the exact combined source diff,
the original build manifest and the pinned workflow/build instructions. The
combined diff is reconstructed in a temporary index using the pinned source's
attributes; neither the upstream ref nor its worktree is changed. Its digest
must match the actual engine producer's recorded `appliedSourceSHA256`.

The filename-based notice index can include tests and tools. All source-level
notices, including comments, remain in the full archive. This preparation does
not determine applicable license obligations or establish compliance, successful
rebuilding, native loading, signing or ordinary-app support. The final candidate
must integrate the applicable notices and corresponding source availability.

`source_notices.verify_engine_source_package(package, source_git,
pinned_wrapper, original_runtime)` independently rechecks the full archive and
notice copies against Git, the 18 patch hashes, producer recipe/order, combined
diff, original build manifest and the three actual pinned framework images.
It rejects a copied manifest without those images, changed/self-reported
receipts, edited notices, symlinks, missing files and unexpected extra files.
The source factory performs this check again before publishing its output.

To include the source metadata and intact notice candidates in a qualification
template, supply all three options to both `prepare-template` and
`verify-template`:

```sh
  --source-package /owned/engine-source-package \
  --source-git /owned/upstream-webkit.git \
  --source-contract /verified/pinned-wrapper
```

The Python assembly/verification APIs accept the equivalent `source_inputs`
dictionary with `package`, `repository` and `contract` Paths. The resulting
`Contents/Resources/EngineSource` resources contain verified notices and source
metadata. The full archive and patches remain in the required companion source
package; the metadata explicitly records that it has not been published. A
source-bearing template cannot be reverified without its independent context.
The app, build and receipt destinations must stay outside these input trees.
`sourceNoticesIntegrated` reports this resource integration only. Native,
sandbox and ordinary-app qualification remain false and signing stays pending.
