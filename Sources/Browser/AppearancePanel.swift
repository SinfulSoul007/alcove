import SwiftUI
import BrowserCore

struct AppearancePanel: View {
    @ObservedObject var store: BrowserStore
    var availableHeight: Double = 640
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("sidebarWidth") private var sidebarWidth = 236.0
    @State private var nameDraft = ""
    @State private var editedSpaceID: UUID?
    private func loadName() { nameDraft = store.space.name; editedSpaceID = store.space.id }
    private func saveName() {
        guard editedSpaceID == store.space.id,let id = editedSpaceID else { return }
        do { try store.renameSpace(id,name:nameDraft); nameDraft = store.space.name } catch { store.message = error.localizedDescription }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack { VStack(alignment: .leading, spacing: 4) { Text("Make it yours").font(.title2.bold()); Text("Customize \(store.space.name)").font(.caption).foregroundStyle(.secondary) }; Spacer(); Button("Done") { store.appearanceVisible = false }.keyboardShortcut(.cancelAction) }.padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack(alignment: .top, spacing: 24) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("SPACE").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            HStack {
                                TextField("Space name",text:$nameDraft).textFieldStyle(.roundedBorder).onSubmit(saveName)
                                Button("Save",action:saveName).disabled(nameDraft.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || nameDraft == store.space.name)
                            }
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 8) {
                                ForEach(SpaceSymbol.allCases) { icon in
                                    Button { do { try store.setSpaceIcon(store.space.id,icon:icon.rawValue) } catch { store.message = error.localizedDescription } } label: { Image(systemName: icon.rawValue).frame(width: 32, height: 30).background(store.space.icon == icon.rawValue ? store.activeTheme.accent.opacity(0.25) : .primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7)) }.buttonStyle(.plain).help(icon.name).accessibilityLabel("Space icon: \(icon.name)")
                                }
                            }
                        }.frame(width: 230)
                        AppearancePreview(theme: store.activeTheme, settings: store.appearance).frame(maxWidth: .infinity).frame(height: 200)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        Text("THEMES").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 6), spacing: 12) {
                            ForEach(SidebarTheme.allCases) { preset in
                                Button { withAnimation(motion) { store.setTheme(preset) } } label: {
                                    VStack(spacing: 6) {
                                        RoundedRectangle(cornerRadius: 10).fill(AppearanceTheme(palette: preset.palette).gradient).frame(height: 48).overlay { if store.space.theme == preset.rawValue && store.space.customTheme == nil { Image(systemName: "checkmark").foregroundStyle(preset.ink) } }
                                        Text(preset.name).font(.system(size: 10)).foregroundStyle(.primary)
                                    }
                                }.buttonStyle(.plain)
                            }
                        }
                        HStack {
                            ColorPicker("Start color", selection: customColor(\.background), supportsOpacity: false)
                            ColorPicker("End color", selection: customColor(\.secondary), supportsOpacity: false)
                            ColorPicker("Accent", selection: customColor(\.accent), supportsOpacity: false)
                        }.font(.system(size: 12))
                        Toggle("Use a gradient", isOn: Binding(get: { store.activeTheme.palette.useGradient }, set: { var palette = store.activeTheme.palette; palette.useGradient = $0; store.setCustomTheme(palette) }))
                        Text("Colors adapt to keep tab text and accents readable.").font(.caption).foregroundStyle(.secondary)
                    }
                    Divider()
                    HStack(alignment: .top, spacing: 28) {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("LAYOUT & TYPE").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            Picker("Density", selection: appearanceBinding(\.density)) { ForEach(SidebarDensity.allCases) { Text($0.rawValue.capitalized).tag($0) } }.pickerStyle(.segmented)
                            HStack { Text("Text size"); Spacer(); Text("\(Int(store.appearance.textScale * 100))%").monospacedDigit().foregroundStyle(.secondary) }
                            Slider(value: appearanceBinding(\.textScale), in: 0.85...1.35, step: 0.05)
                            HStack { Text("Corner rounding"); Spacer(); Text("\(Int(store.appearance.cornerRadius))").monospacedDigit().foregroundStyle(.secondary) }
                            Slider(value: appearanceBinding(\.cornerRadius), in: 4...18, step: 1)
                            Stepper("Favorites columns: \(store.appearance.favoriteColumns)", value: appearanceBinding(\.favoriteColumns), in: 2...6)
                            Text("The grid adapts to narrower sidebars automatically.").font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity)
                        VStack(alignment: .leading, spacing: 16) {
                            Text("BEHAVIOR").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            Toggle("Show website icons", isOn: appearanceBinding(\.showFavicons))
                            Toggle("Always show tab close buttons", isOn: appearanceBinding(\.alwaysShowCloseButtons))
                            Toggle("Animate the interface", isOn: appearanceBinding(\.animationsEnabled))
                            Text("Alcove also respects macOS Reduce Motion.").font(.caption).foregroundStyle(.secondary)
                            Button("Reset sidebar width") { sidebarWidth = 236 }
                            Button("Reset appearance") { store.appearance = AppearanceSettings(); store.setTheme(.midnight); sidebarWidth = 236 }
                            Button("Replay the welcome experience") { store.appearanceVisible = false; store.onboardingVisible = true }.disabled(store.isPrivate)
                        }.frame(maxWidth: .infinity)
                    }.font(.system(size: 12))
                }.padding(24)
            }
        }.frame(width: 720, height: min(640, max(360, availableHeight))).onAppear(perform:loadName).onChange(of:store.space.id) { _,_ in loadName() }
    }
    private var motion: Animation? { store.appearance.animationsEnabled && !reduceMotion ? .easeInOut(duration: 0.2) : nil }
    private func appearanceBinding<Value>(_ path: WritableKeyPath<AppearanceSettings, Value>) -> Binding<Value> {
        Binding(get: { store.appearance[keyPath: path] }, set: { var settings = store.appearance; settings[keyPath: path] = $0; store.appearance = settings })
    }
    private func customColor(_ path: WritableKeyPath<CustomTheme, ThemeColor>) -> Binding<Color> {
        Binding(get: { store.activeTheme.palette[keyPath: path].color }, set: { var palette = store.activeTheme.palette; palette[keyPath: path] = ThemeColor($0); store.setCustomTheme(palette) })
    }
}

struct AppearancePreview: View {
    let theme: AppearanceTheme
    let settings: AppearanceSettings
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 4) { ForEach(0..<3) { _ in Circle().fill(theme.ink.opacity(0.3)).frame(width: 5, height: 5) }; Spacer(); Image(systemName: "sidebar.left").font(.system(size: 9)) }
                RoundedRectangle(cornerRadius: 5).fill(theme.tile).frame(height: 21).overlay(Text("Search or Enter URL…").font(.system(size: 7)))
                HStack(spacing: 5) { ForEach(0..<3) { index in RoundedRectangle(cornerRadius: 6).fill(theme.tile).frame(height: 27).overlay(Image(systemName: ["globe", "sparkles", "book"][index]).font(.system(size: 9)).foregroundStyle(theme.accent)) } }
                Text("Your Space").font(.system(size: 8, weight: .semibold)).opacity(0.5)
                HStack { Image(systemName: "folder.fill").foregroundStyle(theme.accent); Text("Projects") }.font(.system(size: 8))
                HStack { Image(systemName: "globe"); Text("A little room to explore") }.font(.system(size: 8 * settings.textScale)).lineLimit(1).padding(5).background(theme.selected, in: RoundedRectangle(cornerRadius: settings.cornerRadius * 0.6))
                Spacer(minLength: 0)
            }.padding(10).frame(width: 140)
            RoundedRectangle(cornerRadius: settings.cornerRadius).fill(theme.isDark ? Color(white: 0.1) : .white).overlay(Image(systemName: "sun.horizon").font(.system(size: 28, weight: .ultraLight)).foregroundStyle(theme.accent.opacity(0.5))).padding([.trailing, .vertical], 7)
        }.background(theme.gradient).foregroundStyle(theme.ink).clipShape(RoundedRectangle(cornerRadius: 13)).overlay(RoundedRectangle(cornerRadius: 13).stroke(.primary.opacity(0.06)))
    }
}
