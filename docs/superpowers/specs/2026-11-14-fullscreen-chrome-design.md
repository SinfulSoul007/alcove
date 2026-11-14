# Fullscreen navigation visibility

Keep Alcove's navigation usable when entering, occupying and leaving native macOS fullscreen. The same WKWebView and document must stay mounted, including form values. Primary, collapsed-sidebar and Quick Browse layouts share NativeWindowChrome.

## Evidence and approach
An owned titled NSWindow using the unchanged production NativeWindowChrome reproduces the blank 40-point fullscreen strip. Its public contentLayoutRect excludes that strip. Changing only the empty owned toolbar's isVisible to false reveals the original SwiftUI navigation immediately. Normal traffic-light alignment uses that toolbar and must be restored on exit.

Use the existing chrome owner to hide only the empty toolbar it creates while the window's styleMask contains fullScreen, and restore it when the mask clears. Existing resize/fullscreen notifications schedule the reconciliation. Ownership follows the exact toolbar object weakly, so returning a reader to its original window remains correct without retaining windows. A caller-supplied toolbar is not owned and must retain its visibility. No view recreation, guessed fullscreen padding, global presentation options or private AppKit view mutations.

Alternatives: insetting the full page below the opaque empty toolbar wastes space and retains a blank band; rewriting navigation as native toolbar items is a larger layout redesign. The narrow ownership fix preserves normal window behavior.

## Constraints
- macOS minimum 14.0; public AppKit/SwiftUI APIs only.
- Preserve all existing data protection, six entitlements and release identities.
- Do not modify the published v0.9.0-preview.1 tag or its assets.
- Preserve mounted website identity, page state and existing native button ownership.
- This is a fullscreen repair, not full Arc parity or a full-browser completion claim.

## Acceptance
An opt-in real-GUI native titled fixture must fail before the repair because its fullscreen toolbar obscures the top content. It must then pass fullscreen entry/exit, repeated cycles, caller-toolbar and reader-reattachment checks. Existing production BrowserUI/Quick Browse alignment, page hit testing and web-view identity checks must pass. A visible guest experiment must confirm the controls appear in actual fullscreen and return to native alignment after exit. The full project suite and builds are required before publishing a new artifact.
