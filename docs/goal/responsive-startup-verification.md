# Responsive protected-data startup verification

Source baseline605080c (docs over verified c499631). This increment moves default normal-window Keychain access to a coalesced background job, preserves key identity/access policy, gates normal browsing until profile restoration, and bounds queued OS links. Closed stores are weakly referenced and shutdown/Quit rejects late adoption. Private browsing remains available.

Focused25 startup,37 existing store and16 native Quick Browse checks pass with zero failures/compiler diagnostics. Startup checks cover blocked retries and close/reopen, off-main/key-creation policy, private independence, hidden mounted root transition, real menu availability, bounded routing queue, unchanged ciphertext, rejection/retry, wrong keys, fresh onboarding and legacy migration. Live stable Visual Four0.7.2/build14 now shows a responsive loading window during the actual Keychain wait; its Private Window button opened a private window immediately. Full suite/build/review/CI/download-back gates remain pending at this checkpoint.

macOS may still require approval for an ad hoc re-signed app; moving the wait does not remove or weaken that system prompt. No Keychain key/ACL/container, encryption format or entitlement changes were made. This fixes startup responsiveness, not the full browser acceptance goal.

## Rulings and costs
1. Continue in the existing authorized main checkout and push/build workflow; cost if wrong: changes land on shared main.
2. Bound this increment to Keychain startup and dependent lifecycle/routing defects, while retaining the full acceptance goal; cost if wrong: unrelated feature gaps remain meanwhile.
3. Keep explicitly injected synchronous keyProvider fixtures supported; production defaults use background loading; cost if wrong: a caller deliberately injecting a synchronous provider can block its own caller.
4. Use live Computer Use for the SwiftUI Private Window button because a never-shown host exposes no AX children; retain mounted root/menu checks; cost if wrong: native button verification can remain incomplete if app access fails. The live click has now passed.

## Deferred minors
Existing Boost M1 (Copy after Unhide selector state) and Sidebar M1 (floating-mode automated matrix coverage) belong to their separate deferred work. No new review findings have been received yet.
