# Native privacy page construction implementation

> Use superpowers:executing-plans inline. Existing isolated wrapper and native-source worktrees are reused.

**Spec:** `docs/superpowers/specs/2026-11-19-native-privacy-page-construction-design.md`

**Goal:** Remove the proved constructor-time native privacy callback without weakening initial or subsequent privacy enforcement.

## Global constraints

- Upstream pin26695efdefc6076049ec50713a2c4e54b90b4d47. Preserve all13 existing patches; add a separate14th patch.
- Keep frozen previous commits/runtime intact for reproducibility; no public app/version/installer changes here.
- Owned fixtures only; original uBO code unchanged. At most one transient QA process and close afterward.

## Review focus

- Initial overlay is present before page creation/load, even if a page is registered during another privacy update.
- The constructing page must not call its native view client; existing pages still receive ordinary live notification and IPC.
- No shared WKPreferences mutation, baseline overwrite, profile/private widening or permission bypass.
- The event fixture's private grant does not change real browser grants or production event routing.
- Each patch applies in the exact14-patch order; native code compiles on the pinned source. Unknown hosted setup failures remain visible.

### Task 1: Initialize policy before notifying native clients

**Files:** native WebPageProxy.h/.cpp and the Cocoa WebExtensionController implementation; wrapper new construction patch/probe, update-event fixture, build workflow and checksums/docs.

**Interfaces:** Explicit native notification mode for setting a page's extension overlay; per-page effective-policy helper used for initial and live updates.

- [ ] Preserve RED753/755 native stacks and exact prior runtime/source receipts. Preserve756 event fixture proof and757 setup result.
- [ ] Implement synchronous new-page overlay initialization without notification, retaining live updates. Generate a separate native patch on the full preceding13-patch source.
- [ ] Add the positive native constructor regression to the engine gate; fix only the owned event fixture's private grant. Retain fixture logs when hosted setup fails.
- [ ] Verify exact patch application/diff, warning-clean Swift probes and all local orchestrator checks. One fresh whole-branch review, one material fix pass.
- [ ] Build the exact revised engine; run every native gate including fresh-page actual privacy behavior. Verify artifact source/digests and execute both original uBO asset lifecycle checks.
- [ ] Record actual results and remaining blockers; do not publish an unqualified runtime or mark the overall browser goal complete.

Review fix constraints: use one side-effect-free permission snapshot time for initial policy, preserve explicit deny/expiry semantics, retain a stable snapshot of live pages across callbacks, and coalesce the ordinary expiry refresh until after native construction. The actual shared-preferences clipboard expiry witness must construct/load and still clear the expired clipboard preference. One fresh source review is complete; no re-review. Mixed-key expiry/reentrant callback invariants need runtime coverage and are not independently claimed as observed RED→GREEN.
