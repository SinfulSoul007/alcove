# Native runtime error implementation

> Use superpowers:executing-plans inline in the existing isolated wrapper/native workspaces.

**Goal:** Return undefined for absent native runtime errors while preserving actual callback errors and isolation.

**Spec:** `docs/superpowers/specs/2026-11-23-native-runtime-error-design.md`

## Global constraints

- Pin 26695efdefc6076049ec50713a2c4e54b90b4d47; preserve all14 existing patch bytes and frozen 6666768/24cdf33 sources/artifacts.
- No generic nullable conversion, permission, private-access or world widening. No cached caller realm. Public app/downloads unchanged.
- One owned ephemeral native probe at a time; no user profile, browsing address, password or real threat-site request.

## Review Focus

- A real API error must remain available during its callback and clear afterward; test both native success and quota-error callbacks.
- Promise rejection must not create a false callback error state; test rejection plus the outside getter.
- The getter must use the current script realm and preserve MainWorldOnly; inspect generated caller-context forwarding and keep sibling context controls.
- Test startup must diagnose missing readiness without silently skipping HTTPS, swallowing failure, changing private grants or losing loader variables.
- Native build/provenance/runtime/architecture/signing gates stay open until observed; never infer public compatibility from a local primitive test.

### Task 1: Correct absent error values in the native getter

**Files:** Native `WebExtensionAPIRuntime.h`, `Cocoa/WebExtensionAPIRuntimeCocoa.mm`, `Interfaces/WebExtensionAPIRuntime.idl`. Wrapper `diagnostics/webkit-runtime-last-error.patch`, `diagnostics/webkit-runtime-error-probe.swift`, `.github/workflows/build-webkit.yml`, `diagnostics/verify-probe-environment.py` and research documentation.

**Interfaces:** The getter becomes `JSValue *lastError(JSContextRef)` with IDL `[MainWorldOnly, NeedsScriptContext]`. Existing errors return unchanged; absence returns an explicit undefined value in that context. No other API signature changes.

- [ ] Write/run the native error-state witness on exact14 runtime. Expected RED: absent-error checks fail with null, while actual callback-error and promise-rejection controls pass.
- [ ] Implement the three-file getter change, generate patch15 against native24cdf33, verify all preceding patch digests and exact patch application.
- [ ] Add the probe to the engine gate, retain all original witnesses, diagnose/readiness-wait live fixtures for up to60s, and correct Bash3 constructor forwarding. Verify syntax, all actual watchdog loader environments and warning-clean probe compilation.
- [ ] One fresh whole-branch source review; regrade findings, one material fix pass. Freeze and build the exact candidate. Expected GREEN: new error witness and original cache plus native suite pass on provenance-verified new runtime. Preserve any failures and do not restart a live build merely because observation expires.


### Task 2: Rebuild WebKit against the verified dependency baseline

**Files:** Create diagnostics/webkit-dependency-baseline.json, diagnostics/prepare-webkit-dependencies.py and diagnostics/WebKitDependencyChecks.py plus diagnostics/build-webkit-project-only.pl. Modify .github/workflows/build-webkit.yml. The baseline receipt lives in Release/AlcoveDependencyBaseline.json and accompanies the runtime artifact.

**Interfaces:** The helper accepts `prepare --archive ZIP --destination RELEASE --patch-directory diagnostics --contract JSON` and `verify --destination RELEASE`. Prepare verifies the pinned provenance/patches and stages safe cached dependencies, using the lower-product allowlist and excluding all project-owned runtime products/DerivedSources. Verify requires seven unchanged dependency binaries, thirteen regenerated project binaries and a WebKit binary different from the excluded baseline. The Perl launcher consumes the pinned XcodeOptions and invokes the project Everything target once.

- [x] Write/run owned real ZIP/tar fixtures through the CLI: valid import, missing/edited provenance, mismatched dependencies/patches, traversal/unsafe links/duplicates, existing-destination preservation, exclusion of stale generated outputs, executable/symlink preservation post-build byte checks, and a real launcher subprocess that dispatches one compiler command with correct quoted project/options and propagates compiler failure. Expected RED: helper/launcher absent; regression RED: stale project service imported.
- [x] Implement the bounded atomic importer and post-build verifier. Run `python3 diagnostics/WebKitDependencyChecks.py`; expected all behavioral controls pass. Import the actual pinned85MB artifact into an owned temporary directory and inspect the real receipt and dependency bytes; old WebKit must be absent, verify must fail before rebuilding.
- [x] Integrate authenticated read-only artifact download, preparation before the once-only project Everything build, post-build verification and receipt publication. Parse every workflow shell block and retain original native gates. One focused review of the new build/import scope; no repeat review of the unchanged native getter.
- [ ] Commit/push the changed build strategy once. Observe its actual compile/native/artifact result. Only a complete provenance-verified native GREEN can complete the original getter task; keep all browser and public-runtime qualification open.
