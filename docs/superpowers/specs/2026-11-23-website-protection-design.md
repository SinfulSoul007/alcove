# Local website protection

## Intent and evidence

Alcove must warn before opening known phishing destinations, without sending a person's browsing addresses to another service. VM 776 showed Safari warning on Google's harmless phishing test URL while the exact Alcove source loaded it. Public WebKit warning preferences default to enabled; native availability and lookup diagnostics 777–780 do not establish usable provider coverage. Toggling that preference is not a fix.

The user's full-browser request and instruction to continue authorize implementation without another design-approval round. The choices below are the implementer's decisions. They do not narrow the full browser goal or establish release readiness.

## Approach

Keep system WebKit's protection enabled and add an independent local phishing-domain catalog and native warning. An external Google/Web Risk service needs credentials, terms and a privacy design; Apple private provider diagnostics are not a distributable service. Neither is silently enabled. A community catalog is a useful additional layer with a defined, testable scope, not a claim of Safari-equivalent detection.

Use **PhishDestroy's curated Primary list**, excluding its aggregated Community lists. The pinned publisher source is `c22df68d2bded72fdb5415f929556dd220c8056c`; `list.txt` has 233,194 unique ASCII domain entries, 4,875,189 bytes, SHA-256 `9431f1f10334d9bf08991e039045aba63cdc3d490d9ab979140798ddf106af35`. Its content commit is dated `2026-11-23T06:43:18Z`. The publisher's MIT license explicitly permits redistribution and must accompany the data. Do not visit any listed site during development.

## Catalog contract

- Bundle the source data, its unmodified license and versioned provenance metadata in the app. Verify the digest, schema, count, bounded input and domain syntax before use. Reject a corrupt catalog as unavailable; do not silently omit malformed entries.
- Match HTTP/HTTPS hostnames case-insensitively, including subdomains on DNS-label boundaries. Normalize URL host encoding/IDNA and a terminal DNS root dot. User info, ports, paths, queries and fragments never change which hostname is classified. A suffix lookalike must not match.
- An absent match means **not listed**, never safe. The catalog does not classify IP literals, malware files, page content or URL paths. It deliberately does not hardcode Google's test URLs; that test domain is absent from this source.
- Load and validate once per process away from the main actor; use the same immutable catalog for normal and private windows. No browsing address, query, credential, lookup history or warning approval is persisted or uploaded.
- Catalog updates initially travel with app releases. Include a deterministic maintainer refresh/validation command and display the actual data date. Data older than 30 days is marked stale; a new download date does not disguise old content. A separate authenticated data-update channel remains future work.

## Navigation and warning contract

- Apply protection to the actual native navigation-policy path for normal tabs, split panes, Peek, Quick Browse and extension-created website windows, including frames, redirects, form submissions and navigation downloads. Verify actual WebKit redirect behavior with owned servers before relying on it.
- Bind a pending decision to its exact web view, profile and document/request lifetime. Keep the real navigation policy decision pending while a native warning is shown; do not reconstruct a POST, consume a body stream or turn a frame/download into an ordinary GET.
- The safe action cancels that exact request and preserves the mounted current page. Explicit continue allows only that exact pending request through the existing extension/ownership checks. No permanent allow list or global disable is added.
- Cancel decisions once on replacement navigation, document/view teardown, transfer, profile/data transition or shutdown. Old UI callbacks cannot approve another page or a newer request. Bound pending work and reject stale/unpresented approvals.
- A native overlay covers the affected page, identifies the ASCII hostname and list provider, offers a prominent safe action and a separate unsafe continuation. Return/Escape must not silently choose unsafe continuation. Layout must remain usable in narrow/short panes, large text and Reduce Motion.
- Loading or unavailable catalog status is visible. An unavailable catalog requires an explicit per-request choice before browsing; it must not appear as active protection. Preserve existing TLS validation and extension preparation gates.

## Verification and completion limits

Core tests cover digest/schema/size/count/syntax failures, IDNA/encoded/root-dot host variants, exact/subdomain/lookalike behavior, user-info confusion, non-web schemes and freshness. Native tests use owned loopback servers, real views and real navigation decisions: blocked requests never reach the target, safe continuations keep forms/pages, unsafe continuations preserve method/body/frame/download, redirects cannot bypass, and stale/closed/transferred contexts cannot be approved. Test actual warning controls and resize live in the VM, with at most one QA app.

Run required nearby navigation/lifetime suites and full hosted checks before integration. Verify resources and license in both ZIP and mounted DMG. One fresh whole-branch review and one material fix pass follow implementation. This feature alone does not finish full uBlock, broad Chrome compatibility, stable signing/Keychain behavior, malicious-download protection, independent audit, energy performance or Arc fidelity.
