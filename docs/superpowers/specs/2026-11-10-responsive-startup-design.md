# Responsive protected-data startup

The sampled Visual Four main thread blocks in SecItemCopyMatching before a window exists. A Keychain prompt must not freeze Alcove or tempt recovery by deleting its encryption key. Normal startup must immediately present a responsive native loading/recovery window, while Private Window and Quit remain available. No normal website stores or profile edits may occur until saved profile identifiers and routing preferences are restored.

Use a background, process-wide coalesced Keychain request. Keep one pending system lookup across close/reopen; weak store continuations and shutdown guards prevent late adoption/writes. Do not claim a timeout cancels a Security call. Failed lookup or decryption preserves sealed/legacy bytes and allows an explicit interactive retry. Private windows never request a key. Restore/migration saves repaired identifiers before exposing them, and unchanged current documents need no rewrite.

Queue incoming HTTP(S) links until successful restore; route with recovered preferences, reject overflow clearly, clear queue on owner close. Restore compact-only windows after expiring inactive records; retain explicitly requested primary windows. Restored windows must not steal focus from a private window.

Keep macOS14, existing Keychain service/account/access policy, encryption format, six entitlements, stable Visual Four identity and unsigned distribution. Version0.7.2/build14; candidate v0.7.2-preview.1. No public release tag in this increment. Full Arc parity/security/performance goal remains active; unrelated deferred minors and new features are separate increments.
