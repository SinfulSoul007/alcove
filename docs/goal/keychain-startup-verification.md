# Keychain startup authorization verification

The 0.22.1 development candidate prevents automatic startup from waiting on classic login-Keychain authorization. The public0.21 download does not include this change. Explicit **Unlock Local Data** still asks macOS to authorize a protected key; the change does not make a replacement unsigned binary silently inherit access.

## Reproduction and fix

Two independently ad hoc signed owned test apps execute at the same bundle path with the same unique disposable test namespace. The first creates a32-byte key. Changing the binary makes the original production noninteractive lookup wait for authorization; a query using the older UI-fail flag also waits. Each observation is bounded to7seconds and terminates only its owned child. A process-local classic Keychain UI control returns authorization failure promptly. The original creator still reads the same test key, then deletes it. [Original-source diagnostic](https://github.com/SinfulSoul007/alcove/actions/runs/46110382483).

The candidate retains the existing LAContext policy and serializes our metadata operations. A scoped compatibility guard uses the documented public classic Keychain UI getter/setter, restoring the prior process-local state after success or error. Their deprecated C symbols are resolved at runtime with the SDK's unsigned-byte Boolean ABI. If the functions are unavailable, automatic access fails before querying or creating a key. An explicit user request retains normal system authorization. No ACL, trust, TCC, system Keychain setting, key-storage policy or security capability is changed.

[Candidate regression](https://github.com/SinfulSoul007/alcove/actions/runs/46110741623) verifies the exact candidate metadata-key source, prompt denial, unchanged original test key, policy restoration and cleanup. Strict whole-application typechecking also passed. One independent read-only review found no Critical, Important or Minor findings for source integration; it does not authorize release without runtime/package checks.

[Expanded native matrix](https://github.com/SinfulSoul007/alcove/actions/runs/46111062061) verifies creation, denied read, denied create-if-missing without replacement, explicit creator access, normal creator read, policy restoration and deletion of only the temporary test item. All artifact digests, ZIP CRCs and the exact metadata-key source digest were authenticated.

| Actual runtime | CPU | Changed-binary automatic read |
| --- | --- | --- |
| macOS26.7.2 | arm64 | Authorization denied in0.041seconds |
| macOS26.6.1 | x86_64 | Authorization denied in0.036seconds |
| macOS15.8.2 | arm64 | Authorization denied in0.029seconds |

These durations only bound the observed Keychain operation; they are not browser performance measurements. The permanent owned-item regression runs in the source/package CI and its native platform matrix. It never accesses the real Alcove, user or publisher namespaces.

## Remaining gates

The actual followup packaged app still needs startup/recovery/private-window and protected cold-restore checks, including changed-binary explicit authorization. The original0.22 source full-suite job remains independent; its artifact cannot qualify a later source change. Current-source full checks, both optimized architectures and independently verified ZIP/DMG remain required before publication. No followup release is public yet.

The existing VM0.22 build reproduced a real macOS Keychain prompt after a binary change. That older running process is waiting for user authorization and is not modified in place. Same-binary installed restarts passed on ARM and Intel but do not prove signing continuity. Stable signing identity, seamless unsigned updates, actual macOS14, consumer hardware, quarantine/Gatekeeper, broad accessibility, Chrome/uBlock compatibility and broader security review remain open.
