# Vision-Link Hue

> 🏠 **Augmented Reality Lighting Control for Philips Hue**  
> Detect, map, and control your real-world lighting fixtures using on-device AI and Apple's spatial computing stack.

[![Swift](https://img.shields.io/badge/Swift-6.3-orange.svg)](https://swift.org/)
[![Platform](https://img.shields.io/badge/iOS-18.0+-blue.svg)](https://developer.apple.com/ios/)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![CI](https://github.com/tomwolfe/Vision-Link-Hue/workflows/CI/badge.svg)](.github/workflows/ci.yml)

## ✨ Overview

Vision-Link Hue bridges the gap between your physical environment and smart lighting. Using **ARKit 2026**, **RealityKit**, and Apple's **Vision framework**, the app automatically detects lighting fixtures through your camera, estimates their 3D positions, and syncs them with your Philips Hue Bridge for intuitive spatial control.

Built with Swift concurrency, strict type safety, and modern Apple frameworks, Vision-Link Hue delivers a seamless, low-latency experience while respecting device thermal limits and network security best practices.

---

## 🚀 Features

- **AI-Powered Detection**: Real-time bounding box detection using `VNDetectRectanglesRequest` with heuristic classification for ceiling, recessed, pendant, lamp, and strip lights.
- **3D Spatial Mapping**: Projects 2D detections into 3D world coordinates using ARKit raycasting, depth maps, and fallback estimation.
- **Kabsch Calibration**: Advanced affine transformation solver using SVD for precise mapping between ARKit space and Hue Bridge Room Space.
- **Material Recognition**: Leverages ARKit 2026 Neural Surface Synthesis to classify fixture materials (Glass, Metal, Wood, etc.).
- **Hue Bridge Integration**: Full CLIP v2 API support, mTLS with Trust-On-First-Use (TOFU) certificate pinning, and real-time state updates via Server-Sent Events (SSE).
- **Adaptive Thermal Management**: Dynamic inference throttling based on device thermal state to prevent LiDAR/Camera shutdown.
- **OTA-Updatable Rules**: Classification logic is driven by a JSON config, allowing detection rules to be updated without app recompilation.
- **Persistent Mappings**: SwiftData-powered storage for fixture-to-light associations with atomic transactions and spatial validation.
- **Modern UI**: SwiftUI-driven HUD with Liquid Glass styling, phase-animated reticles, and RealityKit view attachments.

---

## 📋 Requirements

| Dependency | Version |
|------------|---------|
| **iOS** | 18.0+ |
| **Xcode** | 16.2+ |
| **Swift** | 6.3 |
| **macOS** | 15.0 (Sequoia) for CI/build |

---

## 🛠️ Architecture

```
Vision-Link Hue
├── 🧠 Engines/
│   ├── DetectionEngine.swift        # Vision + Heuristic classification
│   ├── SpatialCalibrationEngine.swift # Kabsch algorithm (SVD)
│   ├── HueClient.swift              # CLIP v2 + SSE + mTLS
│   ├── SpatialProjector.swift       # ARKit raycast & depth unprojection
│   └── ThermalMonitor.swift         # Adaptive throttling
├── 📦 Models/
│   ├── HueModels.swift              # Bridge resources (Lights, Scenes, Groups)
│   ├── FixtureModels.swift          # Tracked fixtures & detection data
│   └── HueStateStream.swift         # Centralized state & notification actor
├── 🗄️ Services/
│   └── FixturePersistence.swift     # SwiftData atomic transactions
├── 🖥️ Managers/
│   └── ARSessionManager.swift       # AR lifecycle & frame processing
└── 🎨 Views/
    ├── ContentView.swift            # Main orchestrator
    ├── ARViewContainer.swift        # RealityKit ARView wrapper
    └── HUDOverlay.swift             # Liquid glass UI & controls
```

### Key Design Patterns
- **Actor Isolation**: `AppNotificationSystem` and `HueEventStreamActor` isolate high-frequency network events from the MainActor.
- **Dependency Injection**: Centralized `AppContainer` provides deterministic access to services.
- **Protocol-Oriented**: `HueClientProtocol` and `HueNetworkClientProtocol` enable full testability with `MockHueClient`.

---

## 📦 Installation

1. Clone the repository:
   ```bash
   git clone https://github.com/tomwolfe/Vision-Link-Hue.git
   cd vision-link-hue
   ```

2. Open the project in Xcode:
   ```bash
   open VisionLinkHue.xcodeproj
   ```

3. Select an iOS 18+ simulator or physical device and build (`⌘B`).

> ⚠️ **Note**: ARKit features require a physical device. Simulator uses safe fallbacks for detection and spatial math.

---

## 📖 Usage

1. **Discover Bridge**: Launch the app to automatically discover Philips Hue bridges on your local network.
2. **Authenticate**: Press the link button on your Hue bridge, then tap "Create New Key" in the app.
3. **Calibrate (Optional)**: For room-scale accuracy, tap known fixture positions to establish an ARKit-to-Bridge transformation.
4. **Detect Fixtures**: Point your camera at lights. The HUD will overlay detected fixtures with confidence indicators.
5. **Link & Control**: Tap a detected fixture to link it to a Hue light/group. Use the control panel to adjust brightness, color temperature, or recall scenes.

---

## 🧪 Testing & CI

The project includes comprehensive unit tests and a GitHub Actions pipeline.

### Run Tests
```bash
swift test
# or
xcodebuild test -scheme Vision-Link-Hue -destination 'platform=iOS Simulator,name=iPhone 16'
```

### CI/CD
- **Build & Test**: Validates compilation and runs `XCTest` suites on iOS Simulator.
- **SBOM Generation**: Automatically generates a Software Bill of Materials for App Store compliance (`swift package generate-sbom`).
- **Linting**: Checks code formatting and concurrency warnings.

See [`.github/workflows/ci.yml`](.github/workflows/ci.yml) for pipeline configuration.

---

## 🔒 Security

- **Certificate Pinning**: Trust-On-First-Use (TOFU) with SHA-256 public key hashing stored securely in Keychain.
- **mTLS**: All Hue Bridge communication uses mutual TLS.
- **Strict Concurrency**: Full Swift 6.1+ strict concurrency compliance with zero `@unchecked Sendable` suppressions.

---

## 📄 License

This project is licensed under the **MIT License**.  
See the [`LICENSE`](LICENSE) file for details.

---

## 🤝 Contributing

1. Fork the repository.
2. Create your feature branch (`git checkout -b feature/amazing-feature`).
3. Commit your changes (`git commit -m 'Add amazing feature'`).
4. Push to the branch (`git push origin feature/amazing-feature`).
5. Open a Pull Request.

Please ensure all tests pass and the Swift format linter runs cleanly before submitting.

---

## 📞 Support

For issues, feature requests, or questions, please open a [GitHub Issue](https://github.com/tomwolfe/Vision-Link-Hue/issues).

Made with 💡 by Thomas Wolfe.
