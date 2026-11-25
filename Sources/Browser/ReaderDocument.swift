import Foundation

struct ReaderDocument {
    static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
    /// `content` is exclusively the allowlist serializer's output, never raw page HTML.
    static func html(title: String, byline: String, site: String, direction: String, content: String) -> String {
        """
        <!doctype html><html dir="\(direction == "rtl" ? "rtl" : "ltr")"><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'none'; style-src 'unsafe-inline'; img-src 'none'; media-src 'none'; font-src 'none'; connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'">
        <meta name="referrer" content="no-referrer"><meta http-equiv="x-dns-prefetch-control" content="off"><meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escape(title)) — Reader</title><style>
        :root { --paper:#f3ead7; --ink:#352d23; --muted:#71634f; --link:#79501c; --size:20px; --width:720px; --font:Georgia,Charter,serif; color-scheme:light dark; }
        * { box-sizing:border-box; } html { background:var(--paper); color:var(--ink); }
        body { margin:0 auto; padding:clamp(28px,6vw,68px) clamp(20px,5vw,54px) 100px; max-width:calc(var(--width) + 108px); overflow-wrap:break-word; font:var(--size)/1.75 var(--font); -webkit-font-smoothing:antialiased; }
        header { border-bottom:1px solid color-mix(in srgb,var(--ink) 15%,transparent); margin-bottom:2em; padding-bottom:1.4em; }
        .site { font:600 12px/1.5 -apple-system,sans-serif; letter-spacing:.06em; text-transform:uppercase; color:var(--muted); }
        h1 { font-size:2.1em; line-height:1.18; letter-spacing:-.025em; margin:.4em 0; text-wrap:balance; }
        .byline { font:.8em/1.6 -apple-system,sans-serif; color:var(--muted); }
        h2,h3,h4,h5,h6 { line-height:1.3; margin:1.7em 0 .6em; text-wrap:balance; } h2{font-size:1.45em}h3{font-size:1.2em}
        p { margin:0 0 1.2em; } a { color:var(--link); text-decoration-thickness:.06em; text-underline-offset:.16em; }
        a:hover { text-decoration-thickness:.12em; } blockquote { margin:1.5em 0; padding-inline-start:1em; border-inline-start:3px solid var(--muted); color:var(--muted); }
        li { margin:.4em 0; } pre { overflow:auto; padding:1em; background:color-mix(in srgb,var(--ink) 6%,transparent); border-radius:6px; white-space:pre-wrap; }
        code { font:.85em/1.7 ui-monospace,monospace; } table { display:block; max-width:100%; overflow:auto; border-collapse:collapse; margin:1.5em 0; font-size:.85em; }
        th,td { padding:.5em .8em; border:1px solid var(--muted); text-align:start; } figure{margin:1.5em 0}figcaption,caption{font-size:.8em;color:var(--muted)}
        hr { border:0; border-top:1px solid var(--muted); margin:2em 0; } ::selection{background:color-mix(in srgb,var(--link) 25%,transparent)}
        </style></head><body><header><div class="site">\(escape(site))</div><h1>\(escape(title))</h1><div class="byline">\(escape(byline))</div></header><main>\(content)</main></body></html>
        """
    }
}
