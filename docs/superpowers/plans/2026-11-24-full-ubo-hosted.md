# Hosted full uBlock qualification implementation plan

Goal: run the frozen strict original ZIP and CRX witness on hosted macOS 26 against the already built engine, without rebuilding or changing that engine or the browser.

Architecture: a manual-only override of the registered native-erasure-check workflow checks out the pinned engine wrapper separately. A read-only download/verification stage authenticates the successful run and exact artifact, validates the 18 patches, 27 approved roots and complete link graph, then checks all three fresh framework hashes. The separate token-free execution stage builds only BrowserCore and the test harness, starts the frozen owned loopback server, launches the unchanged witness with ordinary developer framework search paths, and records qualification only after all original positive markers and owned cleanup succeed.

Constraints: fixed engine 1fc08bd2013efe318f3d7b7914a24dcf9af07916, upstream 26695efdefc6076049ec50713a2c4e54b90b4d47, original witness SHA256 2155d8b27904ca8105f3debee0d3f30242fa387c13d39d0072ed3fcdfea7b725, SDK 26.5 and arm64/macOS 26. No instrumentation, host GUI, binary commits, remote mutations or weakened assertions. Only the canonical optional WebCore Frameworks link may dangle.

- [x] Write negative tests for source/artifact metadata, missing capability/filtering markers, failures, and forbidden runtime links; verify the tests fail before implementing the consumer.
- [x] Add the frozen witness and byte-identical decoded loopback fixture. Add verifier and bounded execution/cleanup modules under scripts/full-ubo; add the manual-only registered workflow override.
- [x] Verify offline with the existing artifact and exact helper checkout, run consumer contract tests, Python/YAML syntax and Swift parse checks, inspect the diff, then commit validation-only changes with [skip ci].

Review focus: expired or foreign artifacts; changed patch/source records; omitted/dangling/escaping runtime links; premature native exit or missing positive markers; timeout/cancellation followed by owned cleanup. Hosted execution remains required before claiming full uBlock qualification.

Validation: 9 consumer tests pass, including source gates, missing positive markers, token-free framework environment, bounded child timeout, retained ownership journals, and recovery exception revocation. Exact local engine verification passed; real pinned source run/artifact/job metadata passed. Python/YAML syntax and frozen Swift parse passed. Product/resources/owned helpers have no diff from efeedfd8. No hosted run or full uBlock success is claimed.
