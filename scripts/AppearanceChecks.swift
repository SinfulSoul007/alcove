import Foundation
import BrowserCore
var failures = 0
func check(_ value: @autoclosure () -> Bool, _ name: String) { if value() { print("PASS: \(name)") } else { print("FAIL: \(name)"); failures += 1 } }
var settings = AppearanceSettings()
settings.textScale = 9; settings.cornerRadius = -3; settings.favoriteColumns = 200
let safe = settings.normalized
check(safe.textScale == 1.35 && safe.cornerRadius == 4 && safe.favoriteColumns == 6, "Customization bounds prevent unusable text, shapes and grids")
settings = AppearanceSettings(); settings.favoriteColumns = 6
check(settings.columns(for: 196) == 4, "Favorites grid reduces columns in a narrow sidebar")
settings.textScale = 1.35
check(settings.columns(for: 196) == 3, "Larger type reserves enough width for Favorite icons")
settings.density = .compact
check(settings.normalized.rowHeight >= 28, "Compact sidebar retains a usable row hit target")
check(ThemeColor.readableForeground(over: [.white]) == .black, "Light themes choose dark readable text")
check(ThemeColor.readableForeground(over: [.black]) == .white, "Dark themes choose light readable text")
let color = ThemeColor(-1, .infinity, 3)
check(color.red == 0 && color.green == 0.5 && color.blue == 1, "Malformed custom colors normalize safely")
let extremes = CustomTheme(background: .black, secondary: .white, accent: .black)
let displayed = extremes.resolvedForDisplay
let foreground = ThemeColor.readableForeground(over: [extremes.background, extremes.secondary])
let gradientSamples = (0...100).map { displayed.background.mixed(with: displayed.secondary, fraction: Double($0) / 100) }
check(gradientSamples.allSatisfy { foreground.contrast(with: $0) >= 7 }, "Opposite-brightness custom gradient stays readable across its full width")
check(gradientSamples.allSatisfy { displayed.accent.contrast(with: $0) >= 3 }, "Matching accent and background cannot hide folder icons")
check(extremes.background == .black && extremes.secondary == .white, "Display contrast adjustment preserves the chosen colors")
check(OnboardingPolicy.shouldPresent(isPrivate: false, savingEnabled: true, completed: false, hasSavedDocument: false), "A fresh install receives the welcome experience")
check(!OnboardingPolicy.shouldPresent(isPrivate: true, savingEnabled: true, completed: false, hasSavedDocument: false), "Private windows never run or persist onboarding")
check(!OnboardingPolicy.shouldPresent(isPrivate: false, savingEnabled: true, completed: nil, hasSavedDocument: true), "Upgrading an existing session does not replay first-launch setup")
check(OnboardingPolicy.shouldPresent(isPrivate: false, savingEnabled: true, completed: false, hasSavedDocument: true), "Interrupted setup can resume after relaunch")
check(!OnboardingPolicy.shouldPresent(isPrivate: false, savingEnabled: false, completed: false, hasSavedDocument: false), "Locked existing data never masquerades as a fresh install")
let sparse = try? JSONDecoder().decode(AppearanceSettings.self, from: Data("{\"textScale\":999,\"favoriteColumns\":50}".utf8))
check(sparse?.textScale == 1.35 && sparse?.density == .comfortable && sparse?.favoriteColumns == 6, "Appearance decoding supplies defaults and normalizes bounds")
var resize = SidebarResizeState()
resize.begin(at: 236); resize.drag(by: 1000, windowWidth: 1000)
check(resize.temporaryWidth == 360, "Live sidebar drag stays bounded without committing preferences")
check(resize.finish() == 360 && resize.temporaryWidth == nil, "Sidebar width commits only when the resize finishes")
resize.begin(at: 300); resize.drag(by: -40, windowWidth: 1000); resize.cancel()
check(resize.finish() == nil, "Cancelled resize produces no persisted width")
var hover = SidebarHoverState()
let reveal = hover.schedule(); hover.completeReveal(reveal)
let staleHide = hover.schedule(); hover.cancelPending(); hover.completeHide(staleHide)
check(hover.revealed, "Reentering the floating sidebar cancels stale delayed hides")
let staleReveal = hover.schedule(); hover.reset(); hover.completeReveal(staleReveal)
check(!hover.revealed, "Pinning or resetting cancels a pending sidebar reveal")
exit(failures == 0 ? 0 : 1)
