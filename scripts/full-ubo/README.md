# Strict original full uBlock qualification consumer

This branch runs the frozen strict test against the **already built** source engine from `SinfulSoul007/alcove` run `45446004771`, wrapper `1fc08bd2013efe318f3d7b7914a24dcf9af07916`, artifact `14965369072`. It builds BrowserCore and a test executable from app base `efeedfd8bf7e64284762bbcaa3bc8ed4a6134ea9`; it does not build WebKit or the ordinary app bundle. The workflow rejects changes to product sources/resources and the existing owned-store/controller helpers relative to that app base.

The branch overrides the already registered `.github/workflows/native-erasure-check.yml` with a manual-only hosted `macos-26` consumer. GitHub requires manual workflows to exist on the default branch; it supports choosing another branch with `--ref`. The registered workflow filename provides that entry point without changing `main`. After separately reviewing and pushing this exact branch, the parent can dispatch:

```sh
gh workflow run native-erasure-check.yml --repo SinfulSoul007/alcove --ref research/full-ubo-hosted
```

No push, dispatch, merge, tag, or publication is performed by these scripts. `[skip ci]` on the validation-only commit prevents unrelated generic push builds and does not skip the manual qualification.

Before loading the engine, `hosted-qualification.py prepare` verifies the successful push run, repository/branch/head identity, successful original 26 native controls and API gates, artifact identity/expiry/size/digest, original outer ZIP and inner tar hashes, source/build manifest, all 18 patch digests, 27 approved roots and 10,568 members, complete links, and three pinned fresh framework hashes. Exactly one canonical dangling `WebCore.framework/Frameworks -> Versions/Current/Frameworks` link is allowed. Every other dangling, absolute, escaping or omitted-product link is rejected. Verification uses the original helpers from the pinned second checkout without invoking their build/package commands.

The official upstream release assets are downloaded from `gorhill/uBlock` release `1.76.4`, checked against their frozen byte lengths and hashes, and never edited or committed. The strict Swift witness has SHA256 `2155d8b27904ca8105f3debee0d3f30242fa387c13d39d0072ed3fcdfea7b725`. The readable loopback server is a byte-identical decoding of the earlier server, SHA256 `f794350a5330d0511d5af2024bdbd15fc9e09bf8451aac816ef2947e4840d2ff`.

The native child receives a small environment allowlist with no CI tokens. Ordinary `DYLD_FRAMEWORK_PATH` and `__XPC_DYLD_FRAMEWORK_PATH` are reconstructed inside the Python launcher after interpreter startup, pointing to the verified runtime. The unchanged witness checks the actual `Bundle(for: WKWebView)` root. There is no injected library, debugger, interposition, tracing, or host GUI use.

The witness waits for the genuine dashboard's own initial iframe before any test messages, then verifies genuine app/list replies, user-filter write/readback/compilation, real network cancellation measured before the server, cosmetic hiding, disable baseline, fresh reenable, and unchanged installed/upstream code, for both original ZIP and CRX. A zero exit code alone is insufficient: exact positive asset/final markers and both complete native capability controls are required. `qualified: true` also requires successful owned-storage cleanup and no remaining ownership journals. Recovery failure revokes qualification.

Execution is bounded to 40 minutes overall: each harness compilation 420 seconds, native witness 480 seconds, each cleanup 90 seconds, each command log 32 MiB. Timeout/failure/catchable cancellation stops the owned process group, then invokes the original ownership-restricted cleanup mode; an `always()` recovery step repeats cleanup. Hard termination of the hosted VM cannot guarantee application-level cleanup; the job's VM is disposable. Cleanup never targets stores or controllers outside the existing journals. Disposable fixture temporary files are removed only after successful cleanup. Journals and fixture state remain on the disposable runner if cleanup fails, while only bounded logs/receipts are uploaded for 14 days. No engine, extension binaries, keys, or profile directories are uploaded.

`evidence/qualification.json` records the consumer commit, app base, native exit, exact marker verification, actual framework root, cleanup/recovery result, and qualification. `source-run.json`, `source-artifact.json`, `source-jobs.json` and `engine-verified.json` preserve the input checks. A failed or missing run never establishes qualification. Passing this test would qualify this test executable and pinned engine for these exact witnesses; it would not establish that the public app embeds the engine or support every Chrome extension.

Local checks (no native GUI execution):

```sh
python3 -B -m unittest discover -s scripts/full-ubo -p 'test_*.py' -v
python3 -B scripts/full-ubo/hosted-qualification.py verify-local \
  --engine-source /path/to/exact/engine-wrapper-checkout \
  --archive /path/to/artifact.zip --destination /new/owned/runtime
xcrun swiftc -frontend -parse scripts/full-ubo/FullUBlockDashboardReadyChecks.swift
```

The offline destination and its sibling `artifact` directory must not exist. Offline verification deliberately returns `fullOriginalUBlockQualified: false`.

References: [manual workflow dispatch](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/manually-run-a-workflow), [hosted runner labels and architecture](https://docs.github.com/en/actions/reference/runners/github-hosted-runners), [macOS 26 arm64 toolchain inventory](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md).
