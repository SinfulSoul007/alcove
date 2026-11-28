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

## Actual browser update behavior

[Real-app update checks](https://github.com/SinfulSoul007/alcove/actions/runs/46114204213) passed30 checks with zero failures on native Apple Silicon and Intel. The original authenticated internal installer creates and cold-restores a note using the real default Keychain. The unchanged-source0.22.1 candidate is then built normally and copied to the exact same Applications path. Its changed binary exposes explicit local-data recovery without opening an automatic authorization dialog, and its private window opens independently. The original encrypted session remains byte-identical. Restoring the original app bytes still decrypts the original note. Both runs authenticate194 exact candidate input hashes and11 actual compositor capture receipts. No test key provider, application arguments or runtime transport are injected.

This verifies the normal source-built candidate and denied-access behavior. It does not qualify the final universal artifact, successful changed-app explicit authorization or private HTTP navigation. The internal original app is a drawing development build labelled0.21; it is not the public0.21 release. Its restoration is an identity/key-preservation test, not a supported document downgrade.

The dedicated VM's `Programming/browser` source and build now match0.22.1/build34. The obsolete0.22 process was quit normally and its waiting authorization request is no longer active. The previous app bundle is backed up. Live testing of the new app awaits an unlocked VM desktop; no password or lock/security setting is changed by this fix.

## Remaining gates

The actual final universal app still needs fresh startup, real normal/private website browsing, pinned-folder restoration, protected cold restore and independent ZIP/DMG checks. [Full current-source CI](https://github.com/SinfulSoul007/alcove/actions/runs/46112023009) is running. The earlier0.22 drawing-source fullCI passed4,227 results and independent package verification, but cannot qualify this later Keychain change. No followup release is public yet.

Successful changed-binary explicit authorization remains open. Same-binary restarts and restoring the original binary do not prove signing continuity. Stable signing identity, seamless unsigned updates, actual macOS14, consumer hardware, quarantine/Gatekeeper, broad accessibility, Chrome/uBlock compatibility and broader security review remain open.
