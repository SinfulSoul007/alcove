import Foundation

public enum SidebarDensity: String, Codable, CaseIterable, Identifiable {
    case compact, comfortable, spacious
    public var id: String { rawValue }
    public var rowHeight: Double { self == .compact ? 30 : (self == .spacious ? 40 : 34) }
}
public struct ThemeColor: Codable, Equatable, Hashable {
    public var red: Double
    public var green: Double
    public var blue: Double
    private static func bounded(_ value: Double) -> Double { value.isFinite ? min(1, max(0, value)) : 0.5 }
    public init(_ red: Double, _ green: Double, _ blue: Double) { self.red = Self.bounded(red); self.green = Self.bounded(green); self.blue = Self.bounded(blue) }
    enum CodingKeys: CodingKey { case red, green, blue }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(try values.decodeIfPresent(Double.self, forKey: .red) ?? 0.5, try values.decodeIfPresent(Double.self, forKey: .green) ?? 0.5, try values.decodeIfPresent(Double.self, forKey: .blue) ?? 0.5)
    }
    public static let white = ThemeColor(1, 1, 1)
    public static let black = ThemeColor(0, 0, 0)
    public func mixed(with other: ThemeColor, fraction: Double) -> ThemeColor {
        let amount = min(1, max(0, fraction))
        return ThemeColor(red + (other.red - red) * amount, green + (other.green - green) * amount, blue + (other.blue - blue) * amount)
    }
    public func contrast(with other: ThemeColor) -> Double { (max(luminance, other.luminance) + 0.05) / (min(luminance, other.luminance) + 0.05) }
    public var luminance: Double {
        func linear(_ value: Double) -> Double { value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }
    public static func readableForeground(over colors: [ThemeColor]) -> ThemeColor {
        guard !colors.isEmpty else { return .white }
        let whiteContrast = colors.map { 1.05 / ($0.luminance + 0.05) }.min() ?? 1
        let blackContrast = colors.map { ($0.luminance + 0.05) / 0.05 }.min() ?? 1
        return whiteContrast >= blackContrast ? .white : .black
    }
}
public struct CustomTheme: Codable, Equatable {
    public var background: ThemeColor
    public var secondary: ThemeColor
    public var accent: ThemeColor
    public var useGradient: Bool
    public init(background: ThemeColor, secondary: ThemeColor, accent: ThemeColor, useGradient: Bool = true) { self.background = background; self.secondary = secondary; self.accent = accent; self.useGradient = useGradient }
    /// Retain the user's colors in storage while keeping text and accents legible on screen.
    public var resolvedForDisplay: CustomTheme {
        var resolved = self
        let foreground = ThemeColor.readableForeground(over: useGradient ? [background, secondary] : [background])
        let shade: ThemeColor = foreground == .white ? .black : .white
        func samples(_ palette: CustomTheme) -> [ThemeColor] {
            (0...16).map { palette.background.mixed(with: palette.useGradient ? palette.secondary : palette.background, fraction: Double($0) / 16) }
        }
        for step in 0...20 {
            let amount = Double(step) / 20
            resolved.background = background.mixed(with: shade, fraction: amount)
            resolved.secondary = secondary.mixed(with: shade, fraction: amount)
            if samples(resolved).allSatisfy({ foreground.contrast(with: $0) >= 7 }) { break }
        }
        let backgrounds = samples(resolved)
        for step in 0...20 {
            resolved.accent = accent.mixed(with: foreground, fraction: Double(step) / 20)
            if backgrounds.allSatisfy({ resolved.accent.contrast(with: $0) >= 3 }) { break }
        }
        return resolved
    }
}
public struct AppearanceSettings: Codable, Equatable {
    public var density = SidebarDensity.comfortable
    public var textScale = 1.0
    public var cornerRadius = 8.0
    public var favoriteColumns = 3
    public var showFavicons = true
    public var alwaysShowCloseButtons = false
    public var animationsEnabled = true
    public init() {}
    enum CodingKeys: CodingKey { case density, textScale, cornerRadius, favoriteColumns, showFavicons, alwaysShowCloseButtons, animationsEnabled }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        density = try values.decodeIfPresent(SidebarDensity.self, forKey: .density) ?? .comfortable
        textScale = try values.decodeIfPresent(Double.self, forKey: .textScale) ?? 1
        cornerRadius = try values.decodeIfPresent(Double.self, forKey: .cornerRadius) ?? 8
        favoriteColumns = try values.decodeIfPresent(Int.self, forKey: .favoriteColumns) ?? 3
        showFavicons = try values.decodeIfPresent(Bool.self, forKey: .showFavicons) ?? true
        alwaysShowCloseButtons = try values.decodeIfPresent(Bool.self, forKey: .alwaysShowCloseButtons) ?? false
        animationsEnabled = try values.decodeIfPresent(Bool.self, forKey: .animationsEnabled) ?? true
        self = normalized
    }
    public var normalized: AppearanceSettings {
        var copy = self
        copy.textScale = textScale.isFinite ? min(1.35, max(0.85, textScale)) : 1
        copy.cornerRadius = cornerRadius.isFinite ? min(18, max(4, cornerRadius)) : 8
        copy.favoriteColumns = min(6, max(2, favoriteColumns))
        return copy
    }
    public var rowHeight: Double { max(28, density.rowHeight * normalized.textScale) }
    public func columns(for width: Double) -> Int {
        let available = max(100, width - 16)
        let possible = Int(floor(available / (32 * normalized.textScale + 7)))
        return min(normalized.favoriteColumns, max(2, possible))
    }
}
public enum OnboardingPolicy {
    public static func shouldPresent(isPrivate: Bool, savingEnabled: Bool, completed: Bool?, hasSavedDocument: Bool) -> Bool {
        guard !isPrivate, savingEnabled, completed != true else { return false }
        return completed == false || !hasSavedDocument
    }
}
