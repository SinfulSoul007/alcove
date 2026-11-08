import SwiftUI
import BrowserCore

extension ThemeColor {
    var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: 1) }
    init(_ color: Color) {
        let value = NSColor(color).usingColorSpace(.sRGB) ?? .gray
        self.init(value.redComponent, value.greenComponent, value.blueComponent)
    }
}
enum SidebarTheme: String, CaseIterable, Identifiable {
    case midnight, lavender, sage, sand, ocean, rose, forest, ember, slate, iris, cloud, graphite
    var id: String { rawValue }
    var name: String { rawValue.capitalized }
    var palette: CustomTheme {
        switch self {
        case .midnight: return .init(background: .init(0.065, 0.055, 0.12), secondary: .init(0.14, 0.08, 0.20), accent: .init(0.73, 0.64, 1))
        case .lavender: return .init(background: .init(0.84, 0.81, 0.92), secondary: .init(0.93, 0.84, 0.92), accent: .init(0.38, 0.25, 0.62))
        case .sage: return .init(background: .init(0.79, 0.86, 0.82), secondary: .init(0.89, 0.91, 0.78), accent: .init(0.18, 0.40, 0.31))
        case .sand: return .init(background: .init(0.89, 0.85, 0.79), secondary: .init(0.95, 0.84, 0.75), accent: .init(0.55, 0.30, 0.15))
        case .ocean: return .init(background: .init(0.06, 0.15, 0.23), secondary: .init(0.07, 0.27, 0.30), accent: .init(0.36, 0.84, 0.88))
        case .rose: return .init(background: .init(0.91, 0.78, 0.80), secondary: .init(0.96, 0.87, 0.81), accent: .init(0.59, 0.20, 0.35))
        case .forest: return .init(background: .init(0.06, 0.17, 0.13), secondary: .init(0.14, 0.23, 0.17), accent: .init(0.59, 0.86, 0.58))
        case .ember: return .init(background: .init(0.22, 0.10, 0.10), secondary: .init(0.31, 0.18, 0.11), accent: .init(1, 0.65, 0.39))
        case .slate: return .init(background: .init(0.19, 0.23, 0.30), secondary: .init(0.27, 0.28, 0.36), accent: .init(0.66, 0.76, 1))
        case .iris: return .init(background: .init(0.22, 0.12, 0.36), secondary: .init(0.34, 0.17, 0.38), accent: .init(0.92, 0.66, 1))
        case .cloud: return .init(background: .init(0.92, 0.94, 0.96), secondary: .init(0.84, 0.89, 0.95), accent: .init(0.22, 0.39, 0.67))
        case .graphite: return .init(background: .init(0.10, 0.11, 0.12), secondary: .init(0.17, 0.18, 0.20), accent: .init(0.78, 0.84, 0.94))
        }
    }
    var background: Color { palette.background.color }
    var secondary: Color { palette.secondary.color }
    var isDark: Bool { AppearanceTheme(palette: palette).isDark }
    var ink: Color { AppearanceTheme(palette: palette).ink }
    var tile: Color { AppearanceTheme(palette: palette).tile }
    var selected: Color { AppearanceTheme(palette: palette).selected }
}
struct AppearanceTheme {
    let palette: CustomTheme
    private let display: CustomTheme
    let foreground: ThemeColor
    init(palette: CustomTheme) {
        self.palette = palette
        display = palette.resolvedForDisplay
        foreground = ThemeColor.readableForeground(over: palette.useGradient ? [palette.background, palette.secondary] : [palette.background])
    }
    var isDark: Bool { foreground == .white }
    var ink: Color { foreground.color.opacity(isDark ? 0.90 : 0.88) }
    var background: Color { display.background.color }
    var gradient: LinearGradient { LinearGradient(colors: [background, palette.useGradient ? display.secondary.color : background], startPoint: .topLeading, endPoint: .bottomTrailing) }
    var accent: Color { display.accent.color }
    var tile: Color { isDark ? .white.opacity(0.08) : .white.opacity(0.28) }
    var selected: Color { isDark ? .white.opacity(0.13) : .white.opacity(0.56) }
}
