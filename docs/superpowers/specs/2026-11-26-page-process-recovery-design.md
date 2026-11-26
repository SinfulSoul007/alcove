# Page process recovery

The installed browser currently leaves a blank website pane and a global recovery toast. A real retry loads another document but leaves that toast visible; a lost WebKit URL also erases the sidebar address label. This change makes that observed failure understandable and retryable in its own tab.

Use the existing native overlay pattern in `EdgeToEdgeWebHost`. A themed, scrollable card says “This page stopped responding”, shows the saved hostname when available, and provides a native Reload button. The original WKWebView stays mounted and retains its full viewport. Normal, private, split, Peek and Quick views all use this host. Other tabs and unrelated global messages are unaffected. Keep the address label from the saved tab URL when WebKit temporarily has no URL; never infer a secure-connection icon from saved metadata.

I chose the inline card over extending the global toast because recovery belongs to a particular page. Replacing the website with a new error document would lose view ownership and complicate fullscreen, so the overlay remains separate. This is an implementation choice within the user's standing request to finish the browser without further design questions.

Each recovery captures its owning store, profile, document and presentation, using weak source references. A Reload action is valid only while that exact recovery remains current. Navigation and discard clear it; a legitimate same-profile view transfer recreates its recovery in the destination. Late callbacks/buttons from a retired source do nothing. No automatic reload, new persistence, Keychain operation, network permission, signing change or process manipulation.

Verification must cover actual native card/button/frame behavior, retry and stale-button cancellation, tab isolation, navigation/discard/transfer, normal/private state and private zero-key/file behavior. Existing queued-Boost cancellation remains covered. Inspect the installed themed card and address in the VM. System WebKit rendering stability remains a separate open gate; this UI does not establish renderer health or full browser readiness.
