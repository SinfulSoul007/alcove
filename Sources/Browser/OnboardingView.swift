import SwiftUI
import BrowserCore

struct AlcovePortal: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path(); let w = rect.width; let h = rect.height
        p.move(to: CGPoint(x: w * 0.2, y: h * 0.88)); p.addLine(to: CGPoint(x: w * 0.2, y: h * 0.42))
        p.addCurve(to: CGPoint(x: w * 0.8, y: h * 0.42), control1: CGPoint(x: w * 0.2, y: -h * 0.02), control2: CGPoint(x: w * 0.8, y: -h * 0.02))
        p.addLine(to: CGPoint(x: w * 0.8, y: h * 0.88))
        return p
    }
}
struct OnboardingView: View {
    @ObservedObject var store: BrowserStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var step = 0
    @State private var appeared = false
    @State private var drawing = false
    @State private var automaticChecks = false
    @State private var introVisible = true
    private var motion: Animation? { reduceMotion || !store.appearance.animationsEnabled ? nil : .spring(response: 0.5, dampingFraction: 0.86) }
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                store.activeTheme.gradient.ignoresSafeArea()
                Circle().fill(store.activeTheme.accent.opacity(0.1)).frame(width: 520, height: 520).blur(radius: 90).offset(x: 240, y: -140)
                VStack(spacing: 0) {
                    HStack {
                        Text("ALCOVE").font(.system(size: 11, weight: .semibold)).tracking(3).opacity(0.6)
                        Spacer()
                        Button("Skip setup") { finish(saveUpdateChoice: step == 2) }.buttonStyle(.plain).font(.system(size: 12)).opacity(0.6)
                    }.padding(.bottom, 24)
                    ScrollView {
                        VStack(spacing: 24) {
                            if step == 0 { introduction }
                            else if step == 1 { styleStep }
                            else { setupStep }
                        }.frame(maxWidth: .infinity).padding(.vertical, 14)
                    }.scrollIndicators(.hidden)
                    HStack {
                        HStack(spacing: 6) { ForEach(0..<3) { index in Capsule().fill(store.activeTheme.ink.opacity(index == step ? 0.8 : 0.18)).frame(width: index == step ? 23 : 7, height: 5) } }.accessibilityLabel("Setup step \(step + 1) of 3")
                        Spacer()
                        if step > 0 { Button("Back") { withAnimation(motion) { step -= 1 } }.buttonStyle(.plain).padding(.trailing, 12) }
                        Button(step == 2 ? "Start browsing" : "Continue") {
                            if step == 2 { finish(saveUpdateChoice: true) }
                            else { withAnimation(motion) { step += 1 } }
                        }.buttonStyle(.borderedProminent).tint(store.activeTheme.accent).controlSize(.large).keyboardShortcut(.defaultAction)
                    }.padding(.top, 20)
                }
                .padding(32).frame(width: min(900, geometry.size.width - 64), height: geometry.size.height - 80)
                .opacity(appeared ? 1 : 0).offset(y: appeared || reduceMotion ? 0 : 16)
                .allowsHitTesting(!introVisible).accessibilityHidden(introVisible).disabled(introVisible)
                if introVisible {
                    LaunchIntroduction(animate: !reduceMotion && store.appearance.animationsEnabled) {
                        withAnimation(motion) { introVisible = false }
                    }.transition(.opacity).zIndex(1)
                }
            }.foregroundStyle(store.activeTheme.ink)
                .onAppear {
                    automaticChecks = store.preferences.automaticUpdateChecks ?? false
                    withAnimation(motion) { appeared = true }
                    withAnimation(reduceMotion || !store.appearance.animationsEnabled ? nil : .easeInOut(duration: 1.4)) { drawing = true }
                }
        }
    }
    private var introduction: some View {
        VStack(spacing: 22) {
            ZStack {
                RoundedRectangle(cornerRadius: 36).fill(store.activeTheme.tile).frame(width: 150, height: 150).rotationEffect(.degrees(reduceMotion ? 0 : (appeared ? -6 : 6)))
                AlcovePortal().trim(from: 0, to: drawing || reduceMotion ? 1 : 0).stroke(store.activeTheme.accent, style: StrokeStyle(lineWidth: 9, lineCap: .round, lineJoin: .round)).frame(width: 105, height: 114)
                Circle().fill(store.activeTheme.accent).frame(width: 7, height: 7).offset(x: 70, y: -55).opacity(drawing ? 1 : 0)
            }.frame(height: 180).accessibilityHidden(true)
            Text("A little more room\nfor the internet.").font(.system(size: 42, weight: .medium, design: .rounded)).multilineTextAlignment(.center)
            Text("Your tabs, your Spaces, your way.\nA familiar sidebar with a native Mac foundation.").font(.system(size: 15)).multilineTextAlignment(.center).lineSpacing(5).opacity(0.6)
        }.transition(.opacity.combined(with: .offset(x: reduceMotion ? 0 : 18)))
    }
    private var styleStep: some View {
        VStack(spacing: 20) {
            Text("Find your atmosphere.").font(.system(size: 30, weight: .medium, design: .rounded))
            Text("Start with a theme. Every color and detail can be changed later.").font(.system(size: 13)).opacity(0.6)
            AppearancePreview(theme: store.activeTheme, settings: store.appearance).frame(width: 400, height: 210)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(46), spacing: 12), count: 6), spacing: 12) {
                ForEach(SidebarTheme.allCases) { preset in
                    Button { withAnimation(motion) { store.setTheme(preset) } } label: { RoundedRectangle(cornerRadius: 11).fill(AppearanceTheme(palette: preset.palette).gradient).frame(width: 46, height: 38).overlay { if store.space.theme == preset.rawValue { Image(systemName: "checkmark").foregroundStyle(preset.ink) } } }.buttonStyle(.plain).help(preset.name).accessibilityLabel(preset.name)
                }
            }
        }.transition(.opacity.combined(with: .offset(x: reduceMotion ? 0 : 18)))
    }
    private var setupStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Make yourself at home.").font(.system(size: 30, weight: .medium, design: .rounded))
            TextField("Name your first Space", text: Binding(get: { store.space.name }, set: { store.session.spaces[store.spaceIndex].name = String($0.prefix(60)); store.save() })).textFieldStyle(.roundedBorder)
            Picker("Tab density", selection: Binding(get: { store.appearance.density }, set: { var settings = store.appearance; settings.density = $0; store.appearance = settings })) { ForEach(SidebarDensity.allCases) { Text($0.rawValue.capitalized).tag($0) } }.pickerStyle(.segmented)
            Toggle("Check for new versions automatically", isOn: $automaticChecks)
            Text("Alcove checks GitHub at most once a day when this is enabled. Your browsing history is never included. Downloads are installed only when you choose.").font(.caption).opacity(0.6)
            HStack(alignment: .top, spacing: 10) { Image(systemName: "keyboard"); Text("⌘T opens the command bar. Shift-click a link to Peek. Drag the sidebar edge to resize it.").font(.system(size: 12)).lineSpacing(4) }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(store.activeTheme.tile, in: RoundedRectangle(cornerRadius: 12))
            Text("This build is an unsigned preview. macOS may restrict downloads until trusted signing is available.").font(.caption).opacity(0.5)
        }.frame(maxWidth: 480).transition(.opacity.combined(with: .offset(x: reduceMotion ? 0 : 18)))
    }
    private func finish(saveUpdateChoice: Bool) {
        if saveUpdateChoice { store.preferences.automaticUpdateChecks = automaticChecks }
        withAnimation(motion) { store.finishOnboarding() }
    }
}
