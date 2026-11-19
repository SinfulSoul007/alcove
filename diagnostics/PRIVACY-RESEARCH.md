# Native extension privacy qualification

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
