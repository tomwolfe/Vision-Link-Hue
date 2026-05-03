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
    ],
    // Enable SBOM generation for April 2026 App Store security compliance.
    // Run: swift package generate-sbom --format json
    cxxLanguageStandard: .none
)
