# Shared-window implementation verification — in progress

Basec6210cc; isolated feat/shared-windows, dedicated VM. Public0.9.1 source/tag remainsc6210cc. The complete browser goal stays active.

Task1 foundation: the pure BrowserWindowWorkspace model passes47 assertions, zero diagnostics, after an expected missing-model API RED run. Existing core checks pass34, zero diagnostics. Independent selections, shared data edits/reorder, focused persistence projection, logical assignment/claim, closed-window refusal, invalid/duplicate references, restoration and last-window library retention are covered. Input snapshots remain unchanged.

This model has no AppKit/WebKit/Keychain/file/network effects and is not wired into production BrowserStore/AppDelegate yet. It does not establish working native multi-window behavior, stale async-write protection for still-open members, single-writer integration, live WKWebView handoff, source-bound output/Boost/extension safety, encrypted window restoration, UI fidelity or full-browser completion. Tasks2–5 remain required. Logical assignments do not grant profile/extension authority.

Existing sourceCI43683749729 succeeded atc6210cc with2,423 browser+2 ZIP assertions and zero diagnostics. Newv0.9.1-preview.1 is annotated at that commit; releaseCI and public download-back remain separate. New model code is a feature-branch checkpoint, not part of0.9.1.
