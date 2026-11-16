import SwiftUI

/// A short, silent greeting drawn locally before first-run setup.
struct LaunchIntroduction: View {
    let onContinue: () -> Void

    @State private var startedAt: ContinuousClock.Instant?
    @State private var continued = false

    private static let duration: Duration = .seconds(3.15)

    var body: some View {
        GeometryReader { window in
            ZStack(alignment: .bottomTrailing) {
                TimelineView(.animation(paused: startedAt == nil || continued)) { _ in
                    let elapsed = startedAt.map { $0.duration(to: .now) / .seconds(1) } ?? 0
                    Canvas { context, size in
                        drawGreeting(in: context, size: size, elapsed: elapsed)
                    }
                }
                .accessibilityRepresentation {
                    Text("Welcome to Alcove").accessibilityAddTraits(.isHeader)
                }
                skipButton.padding(28)
            }
            .frame(width: window.size.width, height: window.size.height)
        }
        .onExitCommand(perform: continueToSetup)
        .task {
            guard !continued else { return }
            let start = ContinuousClock.now
            startedAt = start
            do { try await Task.sleep(until: start + Self.duration, clock: .continuous) }
            catch { return }
            guard !Task.isCancelled else { return }
            continueToSetup()
        }
    }

    private var skipButton: some View {
        Button(action: continueToSetup) {
            HStack(spacing: 8) {
                Text("Skip intro")
                Image(systemName: "arrow.right").accessibilityHidden(true)
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .frame(minHeight: 40)
            .background(.black.opacity(0.22), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.28), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.defaultAction)
        .accessibilityLabel("Skip opening animation")
    }

    private func continueToSetup() {
        guard !continued else { return }
        continued = true
        onContinue()
    }

    private func drawGreeting(in context: GraphicsContext, size: CGSize, elapsed: Double) {
        let width = size.width
        let height = size.height
        let center = CGPoint(x: width * 0.5, y: height * 0.53)
        let bounds = Path(CGRect(origin: .zero, size: size))
        let opening = smoothProgress(elapsed / 2.95)

        context.fill(bounds, with: .linearGradient(
            Gradient(colors: [Color(red: 0.10, green: 0.08, blue: 0.19), Color(red: 0.055, green: 0.12, blue: 0.18)]),
            startPoint: .zero, endPoint: CGPoint(x: width, y: height)
        ))
        context.fill(bounds, with: .radialGradient(
            Gradient(colors: [Color(red: 0.45, green: 0.24, blue: 0.56).opacity(0.60), .clear]),
            center: CGPoint(x: width * (0.25 + opening * 0.10), y: height * 0.34),
            startRadius: 0, endRadius: max(width, height) * 0.78
        ))
        context.fill(bounds, with: .radialGradient(
            Gradient(colors: [Color(red: 1, green: 0.48, blue: 0.37).opacity(0.10 + opening * 0.24), .clear]),
            center: CGPoint(x: width * (0.69 - opening * 0.16), y: height * 0.78),
            startRadius: 0, endRadius: max(width, height) * 0.51
        ))

        let rimWidth = min(width * 0.66, height * 1.10)
        let rim = AlcovePortal().path(in: CGRect(x: center.x - rimWidth / 2, y: height * 0.01, width: rimWidth, height: height * 1.20))
        context.stroke(rim, with: .linearGradient(
            Gradient(colors: [.white.opacity(0.03), Color(red: 0.94, green: 0.63, blue: 0.83).opacity(0.10 + opening * 0.20), .clear]),
            startPoint: CGPoint(x: width * 0.27, y: height * 0.16), endPoint: CGPoint(x: width * 0.70, y: height * 0.90)
        ), lineWidth: 1)

        let emblem = AlcovePortal().path(in: CGRect(x: center.x - 24, y: height * 0.30 - 19, width: 48, height: 43))
        context.stroke(emblem, with: .color(Color(red: 1, green: 0.89, blue: 0.79)),
                       style: StrokeStyle(lineWidth: 2.4, lineCap: .round))

        let writing = min(1, max(0, (elapsed - 0.20) / 2.04))
        guard writing > 0 else { return }
        let progress = (1 - cos(writing * .pi)) / 2
        let designBounds = Self.lettering.boundingRect
        let scale = min(1.22, width * 0.61 / designBounds.width, height * 0.30 / designBounds.height)
        let placement = CGAffineTransform(
            a: scale, b: 0, c: 0, d: scale,
            tx: center.x - designBounds.midX * scale, ty: center.y - designBounds.midY * scale
        )
        let stroke = Self.lettering.trimmedPath(from: 0, to: progress).applying(placement)
        let warmWhite = Color(red: 1, green: 0.94, blue: 0.85)
        let dawn = Color(red: 1, green: 0.74, blue: 0.68)
        var light = context
        light.addFilter(.blur(radius: 5))
        light.stroke(stroke, with: .color(dawn.opacity(0.52)), style: StrokeStyle(lineWidth: 8, lineCap: .round))
        context.stroke(stroke, with: .linearGradient(
            Gradient(colors: [warmWhite, dawn, warmWhite]),
            startPoint: CGPoint(x: center.x - width * 0.3, y: center.y + 32),
            endPoint: CGPoint(x: center.x + width * 0.3, y: center.y - 32)
        ), style: StrokeStyle(lineWidth: 5.2 * scale, lineCap: .round, lineJoin: .round))
    }

    private func smoothProgress(_ progress: Double) -> Double {
        let fraction = min(1, max(0, progress))
        return fraction * fraction * (3 - 2 * fraction)
    }

    // Pen path in drawing order. Trimming it reveals the centerline from left to right.
    private static let lettering: Path = {
        var path = Path()
        path.move(to: CGPoint(x: 25, y: 157))
        func draw(_ x: CGFloat, _ y: CGFloat, _ a: CGFloat, _ b: CGFloat, _ c: CGFloat, _ d: CGFloat) {
            path.addCurve(to: CGPoint(x: x, y: y), control1: CGPoint(x: a, y: b), control2: CGPoint(x: c, y: d))
        }

        // a
        draw(94, 108, 49, 162, 72, 110)
        draw(101, 141, 117, 103, 111, 125)
        draw(56, 173, 92, 158, 73, 177)
        draw(50, 142, 43, 169, 40, 158)
        draw(93, 113, 59, 122, 80, 109)
        draw(102, 139, 107, 113, 110, 125)
        draw(99, 176, 93, 155, 86, 179)
        draw(140, 144, 111, 174, 129, 158)

        // l
        draw(190, 51, 163, 117, 207, 61)
        draw(145, 103, 177, 43, 156, 77)
        draw(122, 170, 133, 129, 113, 168)
        draw(172, 136, 132, 183, 157, 153)

        // c
        draw(216, 118, 187, 117, 217, 109)
        draw(196, 117, 214, 114, 207, 112)
        draw(164, 162, 180, 123, 164, 147)
        draw(190, 177, 160, 174, 175, 181)
        draw(228, 149, 207, 173, 218, 160)

        // o
        draw(274, 114, 244, 130, 263, 109)
        draw(273, 153, 289, 120, 287, 136)
        draw(234, 176, 262, 169, 248, 181)
        draw(234, 141, 219, 170, 222, 152)
        draw(274, 115, 246, 125, 265, 106)
        draw(315, 128, 275, 134, 291, 144)

        // v
        draw(307, 175, 303, 146, 292, 175)
        draw(359, 122, 328, 175, 348, 148)
        draw(349, 120, 366, 101, 348, 106)
        draw(389, 136, 352, 137, 371, 146)

        // e
        draw(433, 113, 409, 128, 438, 118)
        draw(402, 126, 428, 107, 412, 114)
        draw(392, 172, 384, 145, 378, 165)
        draw(481, 143, 411, 184, 452, 168)
        draw(498, 127, 488, 138, 494, 132)
        return path
    }()
}
