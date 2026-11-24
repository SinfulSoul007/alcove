import SwiftUI
import WebKit

enum ReaderTheme: String, CaseIterable, Identifiable {
    case light = "Light", sepia = "Sepia", dark = "Dark"
    var id: String { rawValue }
    var colors: (String, String, String, String) {
        switch self {
        case .light: return ("#faf9f6", "#242424", "#68645e", "#245ba7")
        case .sepia: return ("#f3ead7", "#352d23", "#71634f", "#79501c")
        case .dark: return ("#202225", "#e1dfda", "#aaa8a3", "#9abef5")
        }
    }
    var paper: Color {
        switch self {
        case .light: return Color(red: 0.980, green: 0.976, blue: 0.965)
        case .sepia: return Color(red: 0.953, green: 0.918, blue: 0.843)
        case .dark: return Color(red: 0.125, green: 0.133, blue: 0.145)
        }
    }
}

@MainActor final class ReaderOverlay: NSHostingView<ReaderPresentation> {
    convenience init(session: ReaderSession) { self.init(rootView: ReaderPresentation(session: session)) }
    required init(rootView: ReaderPresentation) {
        super.init(rootView: rootView)
        identifier = NSUserInterfaceItemIdentifier("AlcoveReader")
        rootView.session.overlay = self
    }
    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

struct ReaderPresentation: View {
    @ObservedObject var session: ReaderSession
    @State private var appearanceVisible = false
    @FocusState private var searchFocused: Bool
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { session.dismiss(restoringFocus: true) } label: { Label("Back to Page", systemImage: "chevron.left") }
                    .help("Exit Reader and return to the original page")
                Spacer(minLength: 0)
                Text("Reader").font(.system(size: 12, weight: .semibold)).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                Button { appearanceVisible.toggle() } label: { Image(systemName: "textformat.size") }
                    .accessibilityLabel("Reading appearance").help("Reading appearance")
                    .popover(isPresented: $appearanceVisible, arrowEdge: .bottom) { appearance }
            }.buttonStyle(.plain).padding(.horizontal, 16).frame(height: 44)
            Divider()
            if session.searchVisible {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Find in article", text: $session.searchText).textFieldStyle(.plain).focused($searchFocused).onSubmit { session.find() }
                        .accessibilityLabel("Find in article")
                    if session.searchResult == false { Text("No matches").font(.caption).foregroundStyle(.secondary) }
                    Button { session.find(backwards: true) } label: { Image(systemName: "chevron.up") }.accessibilityLabel("Previous match")
                    Button { session.find() } label: { Image(systemName: "chevron.down") }.accessibilityLabel("Next match")
                    Button { session.dismissFind() } label: { Image(systemName: "xmark") }.accessibilityLabel("Close article search")
                }.buttonStyle(.plain).padding(.horizontal, 16).frame(height: 38)
                Divider()
            }
            ZStack {
                ReaderWebSurface(web: session.reader).accessibilityHidden(session.state != .ready)
                    .allowsHitTesting(session.state == .ready)
                switch session.state {
                case .loading:
                    VStack(spacing: 14) { ProgressView(); Text("Preparing article…").font(.body) }
                        .frame(maxWidth: .infinity, maxHeight: .infinity).background(session.theme.paper)
                case .failed(let message):
                    VStack(spacing: 16) {
                        Image(systemName: "doc.text.magnifyingglass").font(.system(size: 30)).foregroundStyle(.secondary)
                        Text("Reader Unavailable").font(.title3.bold())
                        Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 360)
                        Button("Back to Page") { session.dismiss(restoringFocus: true) }
                    }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity).background(session.theme.paper)
                case .ready, .closed: EmptyView()
                }
            }
        }.onChange(of: session.searchFocusRequest) { _, _ in searchFocused = true }
            .background(session.theme.paper).environment(\.colorScheme, session.theme == .dark ? .dark : .light)
    }
    private var appearance: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Reading Appearance").font(.headline)
            Picker("Theme", selection: $session.theme) { ForEach(ReaderTheme.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
            Picker("Typeface", selection: $session.sansSerif) { Text("Serif").tag(false); Text("Sans Serif").tag(true) }.pickerStyle(.segmented)
            HStack {
                Text("Text Size")
                Spacer()
                Button { session.textSize = max(14, session.textSize - 2) } label: { Image(systemName: "textformat.size.smaller") }.disabled(session.textSize <= 14).accessibilityLabel("Smaller text")
                Text("\(Int(session.textSize))").monospacedDigit().frame(width: 24)
                Button { session.textSize = min(30, session.textSize + 2) } label: { Image(systemName: "textformat.size.larger") }.disabled(session.textSize >= 30).accessibilityLabel("Larger text")
            }
            Slider(value: $session.lineWidth, in: 480...960, step: 40) { Text("Content Width") }
                .accessibilityLabel("Content width")
            Text("Text is processed locally. Images and interactive content stay on the original page.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(20).frame(width: 300)
    }
}

private struct ReaderWebSurface: NSViewRepresentable {
    let web: WKWebView
    func makeNSView(context: Context) -> WKWebView { web }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

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

struct ReaderControl: View {
    @ObservedObject var store: BrowserStore
    let web: WKWebView?
    var body: some View {
        Button { if let web { store.toggleReader(web) } } label: {
            Image(systemName: active ? "doc.plaintext.fill" : "doc.plaintext").frame(width: 24, height: 26)
        }.buttonStyle(.plain).disabled(web.map { !store.canToggleReader(for: $0) } ?? true)
            .help(active ? "Exit Reader" : "Show Reader")
            .accessibilityLabel(active ? "Exit Reader" : "Show Reader")
    }
    private var active: Bool { web.map { store.readerSession(for: $0) != nil } ?? false }
}
