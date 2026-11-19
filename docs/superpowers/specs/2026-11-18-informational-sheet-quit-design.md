# Quitting from informational browser sheets

A person should be able to quit Alcove from Library, settings, site searches, link routing, appearance, profiles or the update panel. These panels save through their existing immediate actions. Their native SwiftUI sheets currently keep AppKit's default `preventsApplicationTerminationWhenModal = true`, so Quit reaches its action but never reaches the application's termination delegate. Actual default/false/restored-true native behavior was verified in VM732; the original Library symptom was observed in the live 0.19.1 source QA.

Use the public native window policy on only the owned informational sheet. Retain the normal application termination delegate and pending-output choices. Boosts has an editor draft and keeps the blocking policy. Save panels, extension permission reviews, native alerts and nested confirmation sheets retain their own policy. Parent browser windows must be untouched.

The bridge must handle attachment before `sheetParent` exists, panel changes in a reused native sheet, detachment/reparenting, overlapping SwiftUI bridge lifetimes and delayed callbacks after dismantling. Restore the native original policy when the final owner leaves. A blocking owner takes precedence during overlap. The bridge must neither intercept input nor publish browser-state changes.

Keep macOS 14 as the app floor and use public AppKit only. No version bump or public asset replacement in this increment. The complete browser/Arc/extension objective remains open.

Verification: reproduce the failure using the actual BrowserUI sheet and actual Quit action with a cancelling native termination delegate; then cover each informational panel, protected Boosts/nested native sheet, panel changes, scope/lifetime and pending-output termination checks. Hosted full CI and later live VM UI verification remain gates before shipping this change.
