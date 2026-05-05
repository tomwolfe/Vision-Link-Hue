# Vision-Link Hue

> 🏠 **Augmented Reality Lighting Control for Philips Hue**  
> Detect, map, and control your real-world lighting fixtures using on-device AI and Apple's spatial computing stack.

[![Swift](https://img.shields.io/badge/Swift-6.3-orange.svg)](https://swift.org/)
[![Platform](https://img.shields.io/badge/iOS-26.0+-blue.svg)](https://developer.apple.com/ios/)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![CI](https://github.com/tomwolfe/Vision-Link-Hue/workflows/CI/badge.svg)](.github/workflows/ci.yml)

## ✨ Overview

Vision-Link Hue bridges the gap between your physical environment and smart lighting. Using **ARKit 2026**, **RealityKit**, and Apple's **Vision framework**, the app automatically detects lighting fixtures through your camera, estimates their 3D positions, and syncs them with your Philips Hue Bridge for intuitive spatial control.

Built with Swift concurrency, strict type safety, and modern Apple frameworks, Vision-Link Hue delivers a seamless, low-latency experience while respecting device thermal limits and network security best practices.

---

## 🚀 Features

- **AI-Powered Detection**: Real-time bounding box detection using `VNDetectRectanglesRequest` with heuristic classification for ceiling, recessed, pendant, lamp, and strip lights.
- **3D Spatial Mapping**: Projects 2D detections into 3D world coordinates using ARKit raycasting, depth maps, and fallback estimation.
- **Kabsch Calibration**: Advanced affine transformation solver using Newton-Raphson polar decomposition for precise mapping between ARKit space and Hue Bridge Room Space.
- **Material Recognition**: Leverages ARKit 2026 Neural Surface Synthesis to classify fixture materials (Glass, Metal, Wood, etc.).
- **Hue Bridge Integration**: Full CLIP v2 API support, mTLS with Trust-On-First-Use (TOFU) certificate pinning, and real-time state updates via Server-Sent Events (SSE).
- **Matter/Thread Fallback**: Cross-manufacturer smart light support via Matter protocol with automatic fallback when Hue Bridge is unavailable, enabling control of Thread-based lights from any Matter-certified manufacturer.
- **Unified Device Control**: Single control surface for both Hue CLIP v2 and Matter devices with intelligent routing based on availability and latency.
- **Adaptive Thermal Management**: Dynamic inference throttling based on device thermal state to prevent LiDAR/Camera shutdown.
- **OTA-Updatable Rules**: Classification logic is driven by a JSON config, allowing detection rules to be updated without app recompilation.
- **Persistent Mappings**: SwiftData-powered storage for fixture-to-light associations with atomic transactions and spatial validation.
- **Modern UI**: SwiftUI-driven HUD with Liquid Glass styling, phase-animated reticles, and RealityKit view attachments.

---

## 📋 Requirements

| Dependency | Version |
|------------|---------|
| **iOS** | 26.0+ |
| **Xcode** | 17.0+ |
| **Swift** | 6.3 |
| **macOS** | 15.0 (Sequoia) for CI/build |

---

## 🛠️ Architecture

```
Vision-Link Hue
├── 🧠 Engines/
│   ├── DetectionEngine.swift        # Vision + Heuristic classification
│   ├── SpatialCalibrationEngine.swift # Kabsch algorithm (Newton-Raphson polar decomposition)
│   ├── HueClient.swift              # CLIP v2 + SSE + mTLS
│   ├── MatterBridgeService.swift    # Matter/Thread fallback communication
│   ├── SpatialProjector.swift       # ARKit raycast & depth unprojection
│   └── ThermalMonitor.swift         # Adaptive throttling
├── 📦 Models/
│   ├── HueModels.swift              # Bridge resources (Lights, Scenes, Groups)
│   ├── MatterModels.swift           # Matter device & accessory models
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
- **Fallback Strategy**: `MatterBridgeService` provides Matter/Thread-based control as a fallback when Hue Bridge is unavailable, ensuring continuous lighting control.

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

3. Select an iOS 26+ simulator or physical device and build (`⌘B`).

> ⚠️ **Note**: ARKit features require a physical device. Simulator uses safe fallbacks for detection and spatial math.

---

## 📖 Usage

1. **Discover Bridge**: Launch the app to automatically discover Philips Hue bridges on your local network.
2. **Authenticate**: Press the link button on your Hue bridge, then tap "Create New Key" in the app.
3. **Calibrate (Optional)**: For room-scale accuracy, tap known fixture positions to establish an ARKit-to-Bridge transformation.
4. **Detect Fixtures**: Point your camera at lights. The HUD will overlay detected fixtures with confidence indicators.
5. **Link & Control**: Tap a detected fixture to link it to a Hue light/group. Use the control panel to adjust brightness, color temperature, or recall scenes.
6. **Matter Fallback**: If your Hue Bridge is unavailable, the app automatically discovers and connects to Matter-certified lights on your Thread network, providing seamless control across manufacturers.

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
- **Linting**: Checks code formatting and concurrency warnings.

See [`.github/workflows/ci.yml`](.github/workflows/ci.yml) for pipeline configuration.

---

## 🔒 Security

- **Certificate Pinning**: Trust-On-First-Use (TOFU) with SHA-256 public key hashing stored securely in Keychain. Supports multiple pinned certificates for seamless rotation without service disruption.
- **ECDSA Signature Verification**: OTA classification rules are cryptographically signed and verified before parsing, preventing injection attacks.
- **mTLS**: All Hue Bridge communication uses mutual TLS.
- **Strict Concurrency**: Full Swift 6.1+ strict concurrency compliance with minimal `@unchecked Sendable` suppressions only where required by `URLSessionDelegate` protocol constraints.

---

## 📋 API Version Matrix

| Feature | Minimum iOS | Minimum ARKit | Availability Notes |
|---------|------------|---------------|-------------------|
| Core detection (rectangle) | 13.0+ | — | Works on all iOS devices with camera |
| CoreML intent classification | 13.0+ | — | Requires bundled `.mlmodel` |
| 3D spatial projection (raycast) | 11.0+ | 11.0 | Works on LiDAR and non-LiDAR devices |
| Depth map unprojection | 12.0+ | 12.0 | LiDAR devices only for full accuracy |
| World reconstruction | 15.0+ | 15.0 | Requires `.worldReconstructionMode = .automatic` |
| Neural Surface Synthesis (material labels) | 26.0 | 2026 | `frame.sceneDepth?.materialLabel` — runtime checked via `#available(iOS 26, *)` |
| Object anchor tracking | 16.0+ | 16.0 | `ARObjectAnchor` — runtime checked via `#available(iOS 26, *)` |
| RealityKit ViewAttachmentComponent | 26.0 | — | SwiftUI view lifecycle management — runtime checked via `#available(iOS 26, *)` |
| Liquid glass effects | 26.0 | — | `.glassEffect(.liquid)` — runtime checked via `#available(iOS 26, *)` |
| `AnchorEntity.world()` | 26.0 | — | Requires world reconstruction — runtime checked via `#available(iOS 26, *)` |

All speculative iOS 26 / ARKit 2026 APIs include both compile-time (`#if !targetEnvironment(simulator)`) and runtime (`#available(iOS 26, *)`) guards for graceful degradation.

---

## 🏠 Bridge Compatibility

### Philips Hue Bridge Requirements

| Feature | Minimum Firmware | Notes |
|---------|-----------------|-------|
| CLIP v2 API | v2 | All Hue Bridges supporting the new API (Bridge 2.0, Hue Hub) |
| SpatialAware positioning | v1976094010+ (v1.14+) | Requires Bridge firmware v1976+ for `position` resource support |
| Event stream (SSE) | v2 | Real-time state updates via `/eventstream/clip/v2` |
| Group control | v2 | Multi-light control via CLIP v2 groups |
| Scene recall | v2 | Scene activation and scheduling |

### Matter/Thread Fallback

When the Hue Bridge is unavailable, the app supports Matter-certified lights on a Thread network:

- **Matter version**: 1.3+ (Thread 1.3 network)
- **Compatible devices**: Any Matter-certified smart light or bulb
- **Commissioning**: Uses standard Matter pairing via the HomeKit framework
- **Fallback activation**: Automatic when Hue Bridge is unreachable after 5 retries

---

## 🔄 OTA Update Process

Classification rules and material mappings are delivered over-the-air via ECDSA-signed JSON updates.

### Key Rotation Procedure

1. **Generate new ECDSA key pair**:
   ```bash
   openssl ecparam -genkey -name prime256v1 -noout -out new_private_key.pem
   openssl ec -in new_private_key.pem -pubout -out new_public_key.pem
   ```

2. **Sign new classification rules**:
   ```bash
   openssl dgst -sha256 -sign new_private_key.pem -out rules.sig classification_rules.json
   ```

3. **Embed new public key** in the build configuration:
   ```bash
   export ECDSA_DEFAULT_PUBLIC_KEY=$(base64 -i new_public_key.pem)
   ```

4. **Certificate rotation** (for Hue Bridge):
   - The app supports multiple pinned certificates via `CertificatePinStore.secondaryPins`
   - Add the new bridge certificate hash as a secondary pin: `delegate.addSecondaryPin(newHash)`
   - After user confirms the new certificate, call `delegate.handlePinMismatch(newHash)`
   - Once rotation is complete, clear old pins: `delegate.clearSecondaryPins()`

### Debug Build Handling

In DEBUG builds, ECDSA key embedding is skipped to prevent test failures. The `_embeddedPublicKeyBytes` is set to `nil` via `#if DEBUG`, allowing all tests to run without requiring a valid ECDSA key. Set `ENABLE_DEBUG_EMBED=1` to force key embedding in debug builds if needed.

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
