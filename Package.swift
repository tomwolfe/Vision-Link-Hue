// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Vision-Link-Hue",
    platforms: [
        .iOS(.v19)
    ],
    dependencies: [],
    targets: [
        .target(
            name: "VisionLinkHue",
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
