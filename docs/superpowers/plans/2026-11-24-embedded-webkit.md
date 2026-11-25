# Self-contained WebKit app packaging implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Build and qualify a self-contained Alcove engine candidate from the exact runtime that passed original full uBlock, preserving the existing public product and full browser objective.

**Architecture:** Authenticate and freshly stage the pinned engine archive, transform only its bundle layout/load metadata, prove code/data sections unchanged, sign inside out, then run the frozen witness in an actual sandboxed app. The ordinary optimized app and its installed extension flows have a distinct final qualification gate.

**Tech Stack:** Python standard library, Swift/AppKit/WebKit, Apple `install_name_tool`/`codesign`/`otool`, hosted macOS 26.5 arm64.

**Spec:** `docs/superpowers/specs/2026-11-24-embedded-webkit-design.md`

## Global constraints

- Candidate is arm64/macOS 26.5+, based on actual engine minimums; current system-WebKit macOS 14+/Intel path remains intact.
- Engine wrapper `1fc08bd2013efe318f3d7b7914a24dcf9af07916`, WebKit `26695efdefc6076049ec50713a2c4e54b90b4d47`, source artifact `14965369072`; all archive/framework hashes and frozen witness/vendor asset hashes are those in the spec.
- Preserve all 27 roots/10,568 members initially through a recorded destination mapping. No engine rebuild, code/data modification, OS-floor patch, unexplained member pruning or developer environment dependencies.
- No `get-task-allow`, disabled library validation, app-sandbox removal, copied Apple-private entitlements, debugger, tracing, injected libraries or platform-security changes.
- App retains the exact six entitlements in `scripts/Entitlements.plist`. Helper permissions are explicit per-role public permissions and require actual evidence.
- No real profiles, Keychain, credentials or user desktop are used for the native witness. Keep the exact witness SHA and all existing assertions.
- No main/tag/public update or general compatibility claim until its corresponding gate passes. Private-extension support is not proved by the normal-profile witness.

## Review focus

- A partially rewritten dependency graph must fail before an app is signed, rather than mixing custom and system WebKit components.
- Malformed/oversized Mach-O commands, duplicate environment commands, absent header room and unexpected executable images must fail without a partial published output.
- A bundle moved away from the build directory must resolve the same complete engine and services, with no developer variables or embedded environment commands.
- Failed or interrupted sandboxed qualification must preserve ownership journals for safe recovery, and cleanup failure must revoke qualification.
- The normal app, test app and current public system-WebKit app must keep distinct identities and platform/capability claims; harness success alone must not promote the ordinary app.

---

### Task 1: Verified staging and load-metadata derivation

**Files:** Create `scripts/engine/qualified-runtime.json`, `scripts/engine/verified_input.py`, `scripts/engine/macho_metadata.py`, `scripts/engine/test_engine_packaging.py`.

**Interfaces:**
- `verify_and_extract(archive: Path, contract_checkout: Path, destination: Path) -> dict`: validate immutable input using the exact wrapper's existing archive helpers, returning source/hash/member receipts.
- `inspect_image(data: bytes) -> dict`: return arm64 Mach-O identity, minimum OS, install/dependency/rpath/environment commands and section offset/hash inventory.
- `remove_developer_environment(data: bytes) -> bytes`: remove only the approved framework/library-search `LC_DYLD_ENVIRONMENT` commands; preserve all remaining command bytes and every section offset/content byte.
- `verify_derivation(before: bytes, after: bytes, allowed_changes: dict) -> dict`: reject code/data/OS-floor/unknown-load changes and report exact original/derived hashes.

- [x] **Step 1: Write rejection and derivation tests before implementation.** Require failure for wrong wrapper/archive/patch/member/link/framework inputs; malformed command sizes/counts/strings/offsets, unsupported/fat/foreign images, unapproved environment names and section overlap. A synthetic arm64 image with duplicate approved environment commands must retain identical code/data bytes and offsets after removal. A changed section byte or minimum OS must fail derivation. Assert expected errors, not any exception.
- [x] **Step 2: Run `python3 -B -m unittest discover -s scripts/engine -p 'test_*.py' -v`; observe missing implementation RED.** Record exact cases and output in the plan ledger.
- [x] **Step 3: Implement the interfaces.** Import only the pinned clean engine wrapper's trusted archive helpers. Freshly extract the authenticated archive into an owned destination; do not mutate the retained verified engine. Use a complete parsed load-command table and bounds checks, removing approved metadata in place with unchanged section locations. Do not implement executable-code rewriting.
- [x] **Step 4: Run the tests GREEN and inspect all 21 actual input Mach-Os.** Save the exact inventory, verify their arm64/26.5 floor, and prove environment-only derivation preserves every section. Include all actual developer-command variants as fixtures; retain immutable input bytes.
- [x] **Step 5: Commit** the verified import/metadata implementation and ledgered actual results.

### Task 2: Self-contained bundle and sandboxed strict witness

**Files:** Create `scripts/engine/package_candidate.py`, `scripts/engine/verify_candidate.py`, `scripts/engine/signing-policy.json`, `scripts/engine/README.md`, `scripts/engine/qualification.py`; add focused tests to `scripts/engine/test_engine_packaging.py`. Modify test-only `scripts/OwnedWebsiteStores.swift` and `scripts/OwnedExtensionControllers.swift` only for explicitly scoped qualification journal storage. Add a manual branch-only hosted qualification entry through a workflow already registered on main, preserving its normal branch behavior.

**Interfaces:**
- `stage_candidate(app: Path, archive: Path, contract_checkout: Path, output: Path, policy: Path) -> dict`: copy only verified inputs; produce a new complete bundle and pre/post-transform mapping/manifests.
- `verify_candidate(app: Path, manifest: Path) -> dict`: prove exact static closure, member/resource provenance, no developer environment load commands, correct platform/signatures/entitlements and required source/notices.
- Qualification-run UUID derives both helper journals under Foundation's writable qualification-container cache directory; ordinary existing helper callers keep their current default. Cleanup must recover exactly the same run UUID and preserve existing ownership exclusions.

- [ ] **Step 1: Add failing tests** for one unmapped owned dependency, escaped/dangling/omitted resource, unexpected executable, incorrect XPC lookup layout, altered code section, developer command, wrong minimum OS label, copied forbidden entitlement, different journal UUID and cleanup failure. Test move/relocation of the produced app. Preserve ordinary public-package expectations.
- [ ] **Step 2: Run focused tests RED.** Add a Swift non-GUI journal-path test demonstrating the packaged-witness path is writable container storage and rejects malformed run identities without touching another run.
- [ ] **Step 3: Implement the complete explicit layout/dependency map** using the actual graph and WebKit's pinned launcher/startup/sandbox sources. Preserve framework/service bundle identities and required framework `XPCServices` layout, all resources and sibling library relationships. Use Apple tooling for IDs/dependencies/rpaths and Task 1 only for the unsupported developer-command removal. Keep true OS dependencies unchanged. Require sufficient metadata space; never shift code/data to force success.
- [ ] **Step 4: Implement inside-out signing and static verification.** Derive the minimum public per-role permissions from pinned WebKit source and direct tests. Use Hardened Runtime and the same identity consistently; never copy development/private signatures or add disabled library validation. Include source/patch/build/install references and applicable WebKit/third-party notices. Reject incomplete output before atomic publication.
- [ ] **Step 5: Build the exact frozen witness as a separate app bundle.** Use an isolated qualification bundle ID and the production app sandbox policy. Keep the witness byte-identical; package unchanged upstream assets as readable test resources and use scoped writable journals. Launch with developer environment variables cleared, verify no embedded environment commands, then require actual embedded framework root, all 24 existing assertions/capability/ZIP/CRX/final markers and cleanup/recovery success.
- [ ] **Step 6: Dispatch and observe the actual hosted candidate test.** Inspect terminal logs/artifact receipt rather than assuming successful compilation establishes native loading. Download back bounded evidence and authenticate it. Any signing/service/sandbox failure returns to source-based diagnosis, without weakening policy or changing the witness.
- [ ] **Step 7: Run all focused tests GREEN and commit** candidate code, scoped helpers, policy and exact verification results. Record unproved ordinary-app/platform/private/compatibility gates explicitly.

### Task 3: Ordinary app entry point and distribution integration

**Files:** Modify `scripts/build.sh` only for an explicit opt-in candidate build; use Task 2 commands for packaging/verification. Add `docs/embedded-webkit-verification.md`. Modify `Sources/Browser/ExtensionManagerUI.swift`, capability reporting and release/update selection only after the corresponding real app gates pass; actual touched files follow their existing interfaces.

**Interfaces:** Existing default `scripts/build.sh`/`scripts/package.sh` remain system-WebKit/universal/macOS 14+. Opt-in candidate output is distinct and truthfully declares arm64/macOS 26.5. Test qualification and product qualification have separate receipts/booleans.

- [ ] **Step 1: Add failing checks** that a normal app build cannot silently inherit developer search paths, mislabel the engine candidate universal/14+, advertise full uBlock on system WebKit or overwrite a public installer/tag. Assert test-only witness/journals/assets do not enter the ordinary app.
- [ ] **Step 2: Implement and build the actual optimized ordinary entry point** with the exact verified candidate closure/signing policy, using the normal onboarding/sidebar and isolated app data. Static checks must match Task 2 manifest and exact app source/resources/entitlements.
- [ ] **Step 3: Launch a relocated/unpacked ordinary app** and verify genuine extension-manager permission review/install, dashboard readiness, actual network/cosmetic blocking, disable/re-enable, quit/relaunch and removal in an owned profile. Use available approved VM UI or real native application testing; no simulated screenshot, standalone probe or injected test entry counts as ordinary-app success. The existing pending VM unlock request is not repeated; other work continues while GUI is unavailable.
- [ ] **Step 4: After actual ordinary-app success, bind truthful engine capability messaging** to the engine actually loaded; keep private-DNR/parser restrictions and unavailable APIs until separately verified. Keep broader original Chrome/Arc/platform scope open. Do not widen updater minimum/architecture selection based on a test app.
- [ ] **Step 5: Run the relevant full app suite, both default architectures and candidate gates**, one fresh bounded whole-branch review, one material RED-to-GREEN fix pass, then download/mount/relocation/install/update verification appropriate to any proposed release. Document exact commits, signatures, source/notices, platform matrix and remaining gates. Commit/push authorized work; do not publish an unqualified engine package.

## Pre-flight / self-review

Task 2 consumes Task 1's verified input, parsed image and derivation receipts; it must not reinterpret an unverified runtime as equivalent input. Task 3 consumes Task 2's closure/signing/native evidence but owns a separate ordinary-app qualification. The frozen witness remains unchanged while only its test ownership helpers gain a scoped writable journal path. The five review-focus conditions are covered in Tasks 1–3. Unavailable GUI or Apple trust is recorded as missing evidence; it does not redefine the full goal.
