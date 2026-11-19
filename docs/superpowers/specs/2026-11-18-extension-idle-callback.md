# Native idle callbacks for extension pages

Unmodified uBlock Origin calls requestIdleCallback in its MV2 background. VM697
proved WebKit's real implementation is present behind RequestIdleCallbackEnabled,
default off. Enabling it in the supplied extension configuration provides actual
ordinary/timeout callbacks and cancellation, without changing fresh default views.

The unchanged package also calls this API in contentscript.js, vapi-client.js and
its content-script bootstrap. Enable this standard native API consistently in
Alcove-owned regular/private pages, Peek, marketplace, and extension backgrounds
and interface views. Availability must not depend on whether an extension is
installed. Keep website storage and extension approvals independent. Do not inject JavaScript implementations or
change extension package contents. On frameworks without the feature catalog or
setter, preserve the native baseline and keep the rest of extension loading usable.
This does not remove the full-uBO/native-engine compatibility gates.

Use a small guarded WKPreferences helper. A JavaScript shim would bypass the
required native behavior, and enabling only extension backgrounds would miss real
uBlock content-script calls. Enable only this named feature; raw unconfigured
WebKit instances retain their defaults. Other Chrome APIs remain required.
