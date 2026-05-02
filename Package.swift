// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "Vision-Link-Hue",
    platforms: [
        .iOS(.v18)
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
    ]
)
