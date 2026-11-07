// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "Alcove", platforms: [.macOS(.v14)], products: [.executable(name: "Alcove", targets: ["Browser"])], targets: [.target(name: "BrowserCore"), .executableTarget(name: "Browser", dependencies: ["BrowserCore"]), .testTarget(name: "BrowserCoreTests", dependencies: ["BrowserCore"])])
