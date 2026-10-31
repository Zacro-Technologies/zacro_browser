// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ZacroNative",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "ZacroNative", targets: ["ZacroApp"]), .library(name: "ZacroCore", targets: ["ZacroCore"])],
    dependencies: [.package(path: "Engine/CefSwift")],
    targets: [
        .target(name: "ZacroCore"),
        .target(name: "ZacroChromium", dependencies: [.product(name: "CefKit", package: "CefSwift")]),
        .executableTarget(name: "ZacroApp", dependencies: ["ZacroCore", "ZacroChromium"]),
        .testTarget(name: "ZacroCoreTests", dependencies: ["ZacroCore"])
    ],
    swiftLanguageModes: [.v5]
)
