import SwiftUI
import CoreText

/// A finite first-run greeting. No network, sound, persistent timer or saved state.
struct LaunchIntroduction: View {
    let onContinue: () -> Void
    @State private var stroke = 0.0
    @State private var ink = 0.0
    @State private var atmosphere = false

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let span = max(size.width, size.height)
            ZStack {
                LinearGradient(colors: [Color(red: 0.08, green: 0.06, blue: 0.17), Color(red: 0.19, green: 0.12, blue: 0.31), Color(red: 0.07, green: 0.16, blue: 0.23)], startPoint: .topLeading, endPoint: .bottomTrailing)
                glow(Color(red: 0.60, green: 0.39, blue: 0.84), opacity: 0.36, radius: span * 0.53)
                    .offset(x: size.width * (atmosphere ? -0.17 : -0.29), y: -size.height * 0.27)
                glow(Color(red: 0.89, green: 0.54, blue: 0.42), opacity: 0.19, radius: span * 0.45)
                    .offset(x: size.width * (atmosphere ? 0.24 : 0.35), y: size.height * 0.32)
                ZStack {
                    AlcoveLettering().trim(from: 0, to: stroke)
                        .stroke(Color(red: 0.82, green: 0.70, blue: 1).opacity(0.35), style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round)).blur(radius: 6)
                    AlcoveLettering().trim(from: 0, to: stroke)
                        .stroke(.white.opacity(0.94), style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
                    AlcoveLettering().fill(.white.opacity(ink * 0.96))
                }
                .frame(width: max(160, min(590, geometry.size.width - 96)), height: min(205, geometry.size.height * 0.30))
                .accessibilityRepresentation {
                    Text("Welcome to Alcove").accessibilityAddTraits(.isHeader)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(width: size.width, height: size.height)
            .clipped()
            .overlay(alignment: .bottomTrailing) {
                Button(action: onContinue) {
                    HStack(spacing: 8) {
                        Text("Skip intro")
                        Image(systemName: "arrow.right").accessibilityHidden(true)
                    }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 40)
                    .background(.white.opacity(0.12), in: Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
                .accessibilityLabel("Skip opening animation")
                .padding(max(20, min(40, size.width * 0.04)))
            }
            .onExitCommand(perform: onContinue)
            .task {
                withAnimation(.easeInOut(duration: 2.25)) { stroke = 1 }
                withAnimation(.easeOut(duration: 0.6).delay(1.8)) { ink = 1 }
                withAnimation(.easeInOut(duration: 3.2)) { atmosphere = true }
                do { try await Task.sleep(for: .seconds(3.25)) }
                catch { return }
                guard !Task.isCancelled else { return }
                onContinue()
            }
        }
    }

    private func glow(_ color: Color, opacity: Double, radius: CGFloat) -> some View {
        Circle()
            .fill(RadialGradient(colors: [color.opacity(opacity), color.opacity(opacity * 0.4), color.opacity(0)],
                                 center: .center, startRadius: 0, endRadius: radius))
            .frame(width: radius * 2, height: radius * 2)
            .accessibilityHidden(true)
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
