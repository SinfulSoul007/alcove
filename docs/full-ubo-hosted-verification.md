# Original full uBlock qualification

The unchanged original uBlock Origin 1.76.4 passed the strict app-source test executable with the separately source-built engine. This establishes this pinned compatibility result; the public Alcove app still uses system WebKit and does not embed this engine.

## Exact inputs and result

- Consumer source: `c77e625680361dcba700e133dc14656201b21353`; app product sources: `efeedfd8bf7e64284762bbcaa3bc8ed4a6134ea9`.
- Successful [hosted qualification run 45539376893](https://github.com/SinfulSoul007/alcove/actions/runs/45539376893), with 24 native assertions, exit 0, and successful initial and recovery cleanup gates.
- Frozen witness SHA-256: `2155d8b27904ca8105f3debee0d3f30242fa387c13d39d0072ed3fcdfea7b725`.
- Original upstream ZIP SHA-256: `4b1b27ed82e734d508ae6d255933c334f62f256e8a8aece92724b826828e3d5f`; CRX SHA-256: `ee44e69bb7a0e162bf08632929a5059bd676dfaa3ae2267e3c4eb11cc949b21a`.
- Source engine wrapper: `1fc08bd2013efe318f3d7b7914a24dcf9af07916`; WebKit source: `26695efdefc6076049ec50713a2c4e54b90b4d47`. The consumer independently verified engine run `45446004771`, artifact `14965369072`, the archive hashes, all 18 patches, all 27 runtime roots, all 10,568 members, the complete link graph and all three framework hashes before executing it.
- Evidence artifact: `14988357746`, 7,480 bytes, SHA-256 `4195ecbdb573193ca2c9e5e74b4aa4ed4ce06ec642024fbec29199907a4ae2db`. Parent download-back verification authenticated its bytes and rechecked the exact source/artifact/native gates, native capability controls, both asset markers, actual framework origin and cleanup results.

Both original packages were exercised separately through the app's package staging, approval, installation, options and enable/disable code. The genuine dashboard finished its own initial iframe before test messages. Its own application and loaded-list replies succeeded. The dashboard wrote, read back and compiled user filters. Server request counts proved the target script was blocked before reaching the server while the control request passed; the cosmetic target was hidden. Disabling restored both baselines; a fresh enabled extension restored the saved effective rules. Installed code and original archives remained unchanged. Only the reviewed owned-loopback host access was granted.

The executable verified that `Bundle(for: WKWebView)` belonged to the independently verified runtime. Native capability controls reported `privacy: object`, `idle: function`, `updateEvent: function` and `navigationTarget: function` for both packages. This test used ordinary developer framework-search environment variables and did not use process tracing, a debugger, interposition or library injection.

## Remaining product work

The public app integration gate is **false**. This is not a self-contained app-bundle, sandbox/Hardened Runtime, installed-app or public update qualification. Shipping integration must prove correct framework and XPC dependency resolution, resources and code signing without developer framework-search environment variables, then repeat genuine full uBlock behavior in the packaged app.

Static inspection found all 21 regular Mach-O images in this engine graph are arm64 with minimum OS and SDK 26.5; the main framework and XPC bundle plists also declare macOS 26.5. This candidate cannot be described as universal or macOS 14 compatible. The existing macOS 14+/Intel system-WebKit release remains intact. Support for the established targets, broader Chrome-extension APIs/vendors, private-extension behavior, real site compatibility, visual/AX/performance/security checks and the full Arc feature inventory remain open.

The engine's development helper signatures and Apple-private entitlements must not be copied into a shipping policy without a separate package design and verification. No application sandbox or platform protection was weakened for this qualification. The public app and its unsupported-extension messaging have not been changed.

Parent readback files are retained in the shared task workspace at `work/full-ubo-qualified-c77/`, including the original evidence ZIP, metadata, full workflow log, extracted receipts/native log and `parent-readback.json`. Cleanup assertions were matched to the actual native/recovery workflow steps; intentional negative controls in the earlier consumer-test step were excluded.
