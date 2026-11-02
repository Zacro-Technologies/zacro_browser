// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ZacroNative",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "ZacroNative", targets: ["ZacroApp"]), .executable(name: "ZacroTextExtractor", targets: ["ZacroTextExtractor"]), .library(name: "ZacroCore", targets: ["ZacroCore"]), .library(name: "ZacroServices", targets: ["ZacroServices"])],
    dependencies: [.package(path: "Engine/CefSwift")],
    targets: [
        .target(name: "ZacroCore"),
        .target(name: "ZacroServices"),
        .target(name: "ZacroChromium", dependencies: [.product(name: "CefKit", package: "CefSwift")]),
        .executableTarget(name: "ZacroApp", dependencies: ["ZacroCore", "ZacroChromium", "ZacroServices"]),
        .executableTarget(name: "ZacroTextExtractor"),
        .testTarget(name: "ZacroCoreTests", dependencies: ["ZacroCore"]),
        .testTarget(name: "ZacroServicesTests", dependencies: ["ZacroServices"])
    ],
    swiftLanguageModes: [.v5]
)
