// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Vision-Link-Hue",
    platforms: [
        .iOS(.v26)
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0")
    ],
    targets: [
        .target(
            name: "VisionLinkHue",
            dependencies: ["Crypto"],
            path: "VisionLinkHue"
        ),
        .testTarget(
            name: "VisionLinkHueTests",
            dependencies: ["VisionLinkHue"],
            path: "Tests/VisionLinkHueTests"
        )
    ],
    cxxLanguageStandard: .none
)
