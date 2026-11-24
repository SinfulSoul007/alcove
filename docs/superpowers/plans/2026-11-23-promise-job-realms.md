# Promise continuation realms implementation plan

> **For agentic workers:** Use superpowers:executing-plans inline in the existing isolated worktrees.

**Goal:** Resume Promise callbacks in their owning document without changing synchronous navigation semantics.
**Architecture:** Select the job realm when JavaScriptCore queues call-bearing Promise jobs. Rebuild only JavaScriptCore and combine it with the verified existing native runtime without changing its ABI.
**Tech Stack:** C++, Swift/AppKit/WebKit native fixtures, Python loopback server, pinned macOS26.5 toolchain.
**Spec:** docs/superpowers/specs/2026-11-23-promise-job-realms.md

## Global constraints

- Upstream26695efdefc6076049ec50713a2c4e54b90b4d47; all15 prior patch bytes and runtime6b remain frozen.
- No Location workaround, extension package edits, caller-world/permission widening, raw VM scope override or test-only product branches.
- Existing universal public app and downloads remain unchanged. Research arm64/macOS26.5 is not the public release.

## Review Focus

- Bound functions and proxies must use their target realm; revoked proxies must still reject asynchronously without a new synchronous exception.
- Reaction rejection and finally callbacks must select the author handler realm; optimized async functions must resume in their generator realm.
- Stopped/suspended documents must retain native lifecycle handling; no author callback may be revived just to fix URL resolution.
- Cross-window synchronous calls must retain the entry window's relative-navigation semantics.
- Cached runtime composition must verify every retained binary and omit every old JSC product/generated source; an ABI assumption alone is insufficient.

### Task 1: Correct queued continuation context

**Files:** Native Source/JavaScriptCore/runtime/JSGlobalObject.cpp. Wrapper diagnostics/jsc-promise-job-realms.patch, diagnostics/CrossRealmPromiseChecks.swift, diagnostics/cross-realm-server.py and scope documentation.
**Interfaces:** Existing JSGlobalObject::queueMicrotask signature and task argument order remain unchanged; only the queued global and its event-loop dispatch target change for the scoped jobs.

- [x] Reproduce with two real same-origin pages. VM867: 5checks/3failures on both stock and15-patch runtime, with both controls passing. Preserve exact source/logs.
- [x] Extend owned fixture for fulfilled/rejected, settled/pending, bound/proxy/finally handlers and revoked-proxy rejection. Expected old-engine failures retain wrong background URL; no setup or compiler failures qualify as RED.
- [x] Implement handler realm selection through getFunctionRealm and generator realm selection for AsyncFunctionResume. Preserve revoked-proxy fallback and termination; regenerate only patch16 and verify it applies to the exact pin.
- [ ] Run warning-clean fixture compilation, exact patch/previous15 digest checks and scoped source validation. One fresh whole-branch review occurs after Task2 integration; do not claim native GREEN before its rebuilt runtime runs.

### Task 2: Build and qualify the changed JavaScriptCore

**Files:** Add diagnostics/jsc-runtime-baseline.json, a bounded runtime composition helper and real CLI fixtures, .github/workflows/build-jsc-realms.yml. Reuse existing native probes; retain original engine workflow unchanged.
**Interfaces:** Consume exact patch16 and verified6b artifact14874745303. Build the JSC project and its actual lower dependencies from the pin; preserve every non-JSC retained runtime binary byte-for-byte. Publish new runtime/provenance only after checks.

- [x] Inspect pinned build-jsc and project graph to choose its supported JSC-only invocation. Write real importer/composition fixtures before implementation; expected RED for absent helper and stale/mismatched products.
- [x] Implement atomic bounded preparation/composition and source/patch/binary receipts. Omit old JSC/DerivedSources; reject corrupt, unsafe or expired inputs. Verify safe actual baseline import and before-build refusal.
- [ ] Add the cross-realm witness plus all existing native gates to the actual workflow. Parse every shell block and verify actual child loader paths. One fresh source review and one material fix pass before committing/pushing the exact changed candidate.
- [ ] Observe the actual build/native/artifact results, independently verify the downloaded runtime, and run both original uBO packages with the strict dashboard-ready BrowserStore witness. Preserve failures; no completion or public release claim from component-only GREEN.
