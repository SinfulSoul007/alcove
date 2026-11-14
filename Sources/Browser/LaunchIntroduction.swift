import SwiftUI
import CoreText

/// A finite first-run greeting. No network, sound, persistent timer or saved state.
struct LaunchIntroduction: View {
    let animate: Bool
    let onContinue: () -> Void
    @State private var stroke = 0.0
    @State private var ink = 0.0
    @State private var atmosphere = false
    @State private var caption = false

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                LinearGradient(colors: [Color(red: 0.08, green: 0.06, blue: 0.17), Color(red: 0.19, green: 0.12, blue: 0.31), Color(red: 0.07, green: 0.16, blue: 0.23)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Ellipse().fill(Color(red: 0.60, green: 0.39, blue: 0.84).opacity(0.30))
                    .frame(width: geometry.size.width * 0.85, height: geometry.size.height * 0.70)
                    .blur(radius: 100).offset(x: atmosphere ? -130 : -230, y: -150)
                Ellipse().fill(Color(red: 0.89, green: 0.54, blue: 0.42).opacity(0.13))
                    .frame(width: geometry.size.width * 0.65, height: geometry.size.height * 0.60)
                    .blur(radius: 110).offset(x: atmosphere ? 200 : 280, y: 170)
                VStack(spacing: 12) {
                    ZStack {
                        AlcoveLettering().trim(from: 0, to: stroke)
                            .stroke(Color(red: 0.82, green: 0.70, blue: 1).opacity(0.35), style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round)).blur(radius: 6)
                        AlcoveLettering().trim(from: 0, to: stroke)
                            .stroke(.white.opacity(0.94), style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
                        AlcoveLettering().fill(.white.opacity(ink * 0.96))
                    }
                    .frame(width: max(160, min(590, geometry.size.width - 96)), height: min(205, geometry.size.height * 0.30))
                    .accessibilityHidden(true)
                    Text("Make room for what matters.")
                        .font(.system(size: 16, weight: .regular)).tracking(0.5)
                        .foregroundStyle(.white.opacity(0.66)).opacity(caption ? 1 : 0)
                }.offset(y: -10).frame(maxWidth: .infinity, maxHeight: .infinity)
                VStack {
                    HStack {
                        Text("A LITTLE ROOM TO EXPLORE").font(.system(size: 9, weight: .medium)).tracking(2.6).foregroundStyle(.white.opacity(0.40))
                        Spacer()
                        Button("Skip intro", action: onContinue).buttonStyle(.plain)
                            .font(.system(size: 12)).foregroundStyle(.white.opacity(0.65))
                            .accessibilityLabel("Skip opening animation")
                    }
                    Spacer(minLength: 20)
                    HStack {
                        Text("YOUR INTERNET, AT HOME.").font(.system(size: 9, weight: .medium)).tracking(2.4).foregroundStyle(.white.opacity(0.40))
                        Spacer()
                        Button(action: onContinue) {
                            Image(systemName: "arrow.right").font(.system(size: 17, weight: .medium))
                                .frame(width: 48, height: 36).foregroundStyle(.white.opacity(0.85))
                                .background(.white.opacity(0.08), in: Capsule())
                                .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1))
                        }.buttonStyle(.plain).keyboardShortcut(.defaultAction).accessibilityLabel("Continue to setup")
                    }
                }.padding(max(20, min(40, geometry.size.width * 0.04)))
            }.clipped().accessibilityLabel("Welcome to Alcove")
                .onExitCommand(perform: onContinue)
                .task(id: animate) {
                    guard animate else { onContinue(); return }
                    withAnimation(.easeInOut(duration: 2.25)) { stroke = 1 }
                    withAnimation(.easeOut(duration: 0.6).delay(1.8)) { ink = 1 }
                    withAnimation(.easeOut(duration: 0.7).delay(1.55)) { caption = true }
                    withAnimation(.easeInOut(duration: 3.2)) { atmosphere = true }
                    do { try await Task.sleep(for: .seconds(3.25)) }
                    catch { return }
                    guard !Task.isCancelled else { return }
                    onContinue()
                }
        }
    }
}

private struct AlcoveLettering: Shape {
    // CoreText supplies the locally installed font's vector outlines once. Only
    // the stroke and opacity animate; no fonts or artwork are downloaded.
    private static let lettering: CGPath = {
        let font = CTFontCreateWithName("SnellRoundhand" as CFString, 220, nil)
        let text = NSAttributedString(string: "alcove", attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
        let line = CTLineCreateWithAttributedString(text)
        let result = CGMutablePath()
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let count = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            glyphs.withUnsafeMutableBufferPointer { CTRunGetGlyphs(run, CFRange(location: 0, length: 0), $0.baseAddress!) }
            positions.withUnsafeMutableBufferPointer { CTRunGetPositions(run, CFRange(location: 0, length: 0), $0.baseAddress!) }
            for index in 0..<count {
                guard let path = CTFontCreatePathForGlyph(font, glyphs[index], nil) else { continue }
                result.addPath(path, transform: CGAffineTransform(translationX: positions[index].x, y: positions[index].y))
            }
        }
        return result
    }()

    func path(in rect: CGRect) -> Path {
        let path = Self.lettering, bounds = path.boundingBoxOfPath
        guard bounds.width > 0, bounds.height > 0 else { return Path() }
        let scale = min(rect.width / bounds.width, rect.height / bounds.height) * 0.94
        var transform = CGAffineTransform(a: scale, b: 0, c: 0, d: -scale, tx: rect.midX - bounds.midX * scale, ty: rect.midY + bounds.midY * scale)
        return Path(path.copy(using: &transform) ?? path)
    }
}
