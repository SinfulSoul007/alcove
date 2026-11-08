import SwiftUI

enum SidebarTheme: String, CaseIterable, Identifiable {
    case midnight, lavender, sage, sand
    var id: String { rawValue }
    var name: String { rawValue.capitalized }
    var isDark: Bool { self == .midnight }
    var background: Color {
        switch self {
        case .midnight: return Color(red: 0.065, green: 0.055, blue: 0.12)
        case .lavender: return Color(red: 0.84, green: 0.81, blue: 0.92)
        case .sage: return Color(red: 0.79, green: 0.86, blue: 0.82)
        case .sand: return Color(red: 0.89, green: 0.85, blue: 0.79)
        }
    }
    var ink: Color { isDark ? Color(red: 0.87, green: 0.86, blue: 0.96) : Color(red: 0.18, green: 0.18, blue: 0.24) }
    var tile: Color { isDark ? .white.opacity(0.085) : .white.opacity(0.35) }
    var selected: Color { isDark ? .white.opacity(0.12) : .white.opacity(0.6) }
}
