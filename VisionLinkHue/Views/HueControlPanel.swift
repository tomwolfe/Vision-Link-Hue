import SwiftUI
import RealityKit
import simd

/// Control panel with sliders for brightness and color temperature.
/// Anchored to a detected fixture via `ViewAttachmentComponent`.
///
/// Uses the fixture's `mappedHueLightId` (set via tap-to-link) to control
/// individual Hue lights, falling back to the selected light group.
struct HueControlPanel: View {
    
    let fixture: TrackedFixture
    let hueClient: HueClient
    let stateStream: HueStateStream
    
    @State private var brightnessValue: Double = 50
    @State private var colorTempValue: Double = 4000
    @State private var isOn: Bool = true
    
    /// Current light state from the stream, resolved via the fixture-to-light mapping.
    private var currentLight: HueLightResource? {
        if let lightId = fixture.mappedHueLightId {
            return stateStream.light(by: lightId)
        }
        return nil
    }
    
    var body: some View {
        VStack(spacing: 12) {
            // Header with fixture type and confidence
            HStack {
                Text(fixture.type.displayName)
                    .font(.subheadline.bold())
                    .foregroundStyle(.primary)
                
                Spacer()
                
                // Confidence badge
                Text("\(Int(fixture.detection.confidence * 100))%")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(
                        confidenceColor(for: fixture.detection.confidence)
                    )
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary.opacity(0.5), in: Capsule())
            }
            
            Divider()
            
            // Power toggle
            HStack {
                Label("Power", systemImage: "power")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                Spacer()
                
                Toggle("", isOn: $isOn)
                    .labelsHidden()
                    .tint(.blue)
                    .onChange(of: isOn) { _, newValue in
                        controlLight { lightId in
                            try await hueClient.togglePower(resourceId: lightId, on: newValue)
                        }
                    }
            }
            
            // Brightness slider
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Label("Brightness", systemImage: "sun.max")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    
                    Spacer()
                    
                    Text("\(Int(brightnessValue))%")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                
                Slider(
                    value: $brightnessValue,
                    in: 0...100,
                    onEditingChanged: { changed in
                        if !changed {
                            controlLight { lightId in
                                try await hueClient.setBrightness(resourceId: lightId, brightness: Int(brightnessValue))
                            }
                        }
                    }
                )
                .tint(.yellow)
            }
            
            // Color temperature slider
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Label("Color Temp", systemImage: "thermometer.medium")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    
                    Spacer()
                    
                    Text("\(Int(colorTempValue))K")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                
                Slider(
                    value: $colorTempValue,
                    in: 2000...6500,
                    onEditingChanged: { changed in
                        if !changed {
                            controlLight { lightId in
                                let mireds = Int(1000000.0 / colorTempValue)
                                try await hueClient.setColorTemperature(resourceId: lightId, mireds: mireds)
                            }
                        }
                    }
                )
                .tint(.orange)
            }
        }
        .padding(16)
        .glassEffect(.liquid, alignment: .center)
        .cornerRadius(16)
        .frame(width: 220)
    }
    
    private func confidenceColor(for confidence: Double) -> Color {
        switch confidence {
        case 0.9...:
            return .green
        case 0.85...:
            return .green.opacity(0.8)
        case 0.7...:
            return .yellow
        default:
            return .red
        }
    }
    
    /// Execute a light control operation, preferring the fixture's mapped Hue
    /// light ID, falling back to the selected group.
    private func controlLight(_ operation: @escaping (String) async throws -> Void) {
        if let lightId = fixture.mappedHueLightId {
            Task {
                do {
                    try await operation(lightId)
                } catch {
                    await stateStream.reportError(error, severity: .error, source: "HueControlPanel")
                }
            }
        } else if let groupId = stateStream.selectedGroupId {
            Task {
                do {
                    try await operation(groupId)
                } catch {
                    await stateStream.reportError(error, severity: .error, source: "HueControlPanel")
                }
            }
        }
    }
}
