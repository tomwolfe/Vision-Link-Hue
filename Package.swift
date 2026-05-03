// swift-tools-version: 6.3
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
            path: "VisionLinkHue",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "VisionLinkHueTests",
            dependencies: ["VisionLinkHue"],
            path: "Tests/VisionLinkHueTests",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        )
    ]
)
