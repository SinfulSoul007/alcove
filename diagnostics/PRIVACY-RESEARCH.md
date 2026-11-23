# Native extension compatibility qualification

This branch is an experimental WebKit build, separate from Alcove's public DMG.
It does not establish full uBlock Origin or general Chrome extension support.

The patch series is pinned to WebKit
`26695efdefc6076049ec50713a2c4e54b90b4d47`. The native privacy facade provides
`networkPredictionEnabled`, `webRTCIPHandlingPolicy`, and
`hyperlinkAuditingEnabled` through owned JavaScriptCore methods, permission-checked
UI-process operations, real browser preferences, and key-specific change events.
It supports callbacks, promises, extension installation precedence, and all four
ChromeSetting scopes. Private session lifetime follows actual private windows.
The per-page overlay preserves the embedder's shared WKPreferences object.

The allocator patch adds WebKit's typed allocator annotations to the pending navigation
target and effective preferences store. The former produced the concrete
`WTFIsFastMallocAllocated` compile error in run 44363135515; both are heap-allocated
with WTF::makeUnique in this series.

The menu-target patch separately accepts opaque URI targets such as `abp:*` only
for extension menus. Native menu items retain these separately from structured
patterns, replace both sets on update, and match either set for link/media targets.
General host, document and content-script patterns keep their existing parser.
The native Swift probe opens and closes actual context menus and checks creation,
matching, click delivery, updates, removal and unchanged grants. Stock WebKit is
an expected negative; changed-engine runtime behavior remains a qualification gate.

The final result-string patch fixes the concrete privacy callback compile error
from run 44404820194. Its JSON null success token is explicitly a WTF String,
which can be converted to Expected<String, WebExtensionError> at the completion
boundary; an ASCIILiteral would require two implicit user conversions.

The standalone Swift probe requires the changed framework, observes real loopback
audit requests, checks shared-preference/controller isolation, tests scope and
permission lifecycle, and verifies expiry using actual UDP STUN traffic. Its expiry
case first materializes the override under a one-hour grant, then shortens the same
grant to three seconds without a later settings call that could hide a missing
native timer. Stock WebKit is an expected negative control, not a successful
qualification of the patch.

Before app integration, preserve privacy settings during ordinary context unload
without leaving a stale context authorized, and supply durable extension
installation dates before load. Pending extension update staging and approved
runtime.reload consumption are separate requirements. The unchanged full original
uBlock Origin ZIP and CRX still need network and cosmetic filtering tests against
the integrated app. Keep the public compatibility gates until that evidence exists.

## Runtime error candidate

The 15th patch changes only `runtime.lastError`'s absent value from JavaScript
null to undefined. The getter receives its current script context through the
existing `NeedsScriptContext` binding attribute; actual error objects, access
tracking and the `MainWorldOnly` boundary remain intact. It does not cache a
caller realm or alter generic nullable conversions.

On the provenance-verified 14-patch runtime from wrapper `6666768`, VM job800
reproduced five absent-value failures. Four positive controls passed: successful
and failed callbacks retained their void argument shape, actual quota errors
retained their messages, and promise-style failure still rejected. The new
`webkit-runtime-error-probe.swift` must pass on a rebuilt engine, together with
the original request-cache and remaining native witnesses. Source preflight is
not native qualification.

The previous hosted engine compiled successfully, but its HTTPS fixture never
published a port during the original ten-second readiness window. The workflow
now observes a still-live fixture for up to sixty seconds and records its process
and sample on timeout; timeout and early exit still fail. This improves evidence
without establishing that slow initialization was the cause. Constructor probe
arguments now forward through a function so system Bash 3 handles the no-argument
case under `set -u`.

Real unmodified uBlock Origin 1.76.4 ZIP and CRX have each demonstrated network
and cosmetic filtering, disable, re-enable and saved-rule restoration in separate
owned runs. A combined run still stalls when the second context starts. This
runtime error candidate does not explain that stall: uBlock checks for an error
object, and the old absent null value does not enter that rejection branch.
The public DMG still uses system WebKit; this research engine is arm64 with a
macOS 26.5 minimum and has not passed distribution qualification.
