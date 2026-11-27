# Embedded-engine packaging components

This development checkpoint authenticates the pinned engine input, stages its
complete bundle layout, plans relative dependencies and relocates individual
image copies or the complete engine tree. It does not yet produce a signed candidate app. The ordinary app
and public downloads continue to use system WebKit.

Run the complete component suite from the repository root:

```sh
python3 -B -m unittest discover -s scripts/engine -p 'test_*.py' -v
```

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

Apple documents [the matching-Team library-validation requirement](https://developer.apple.com/library/archive/documentation/Security/Conceptual/CodeSigningGuide/Procedures/Procedures.html)
and [free Xcode Personal Teams](https://developer.apple.com/help/account/basics/about-your-developer-account/).
A legitimate development identity is a possible local-test route, not evidence
that this engine runs, and not a replacement for public distribution
qualification. Developer ID/notarization and public shipping have separate
[Apple requirements](https://developer.apple.com/developer-id/).
