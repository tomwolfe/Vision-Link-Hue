import SwiftUI
import RealityKit
import simd

/// 3D reticle overlay shown at detected fixture positions.
/// Uses phaseAnimator to pulse when detection confidence is low.
struct FixtureReticle: View {
    
    let fixture: TrackedFixture
    let onSelect: () -> Void
    
    /// Threshold below which the reticle pulses to indicate low certainty.
    private let lowCertaintyThreshold: Double = 0.85
    
    /// Whether the detection confidence is below the threshold.
    private var isLowCertainty: Bool {
        fixture.detection.confidence < lowCertaintyThreshold
    }
    
    var body: some View {
        ZStack {
            // Outer ring - glass effect
            Circle()
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            .white.opacity(0.6),
                            .blue.opacity(0.3),
                            .white.opacity(0.1)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    lineWidth: 2
                )
                .frame(width: 60, height: 60)
            
            // Inner crosshair
            VStack(spacing: 0) {
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [.white.opacity(0.8), .clear],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 1.5, height: 12)
                    .offset(y: -8)
                
                Circle()
                    .fill(.white.opacity(0.9))
                    .frame(width: 4, height: 4)
                
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [.white.opacity(0.8), .clear],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 1.5, height: 12)
                    .offset(y: 8)
            }
            
            // Horizontal crosshair
            HStack(spacing: 0) {
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [.white.opacity(0.8), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: 12, height: 1.5)
                    .offset(x: -8)
                
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [.clear, .white.opacity(0.8)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: 12, height: 1.5)
                    .offset(x: 8)
            }
            
            // Confidence indicator (arc at top)
            if fixture.detection.confidence > 0 {
                Circle()
                    .trim(from: 0, to: 1.0)
                    .stroke(
                        LinearGradient(
                            colors: confidenceColor(for: fixture.detection.confidence),
                            startPoint: .leading,
                            endPoint: .trailing
                        ),
                        style: StrokeStyle(lineWidth: 3, lineCap: .round)
                    )
                    .rotation(.degrees(-90))
                    .frame(width: 70, height: 70)
                    .opacity(0.7)
            }
        }
        .phaseAnimator([1.0, 1.15]) { content, phase in
            content
                .scaleEffect(phase)
                .opacity(isLowCertainty ? 0.5 + phase * 0.5 : 1.0)
        } animation: { phase in
            if isLowCertainty {
                .easeInOut(duration: 1.5).repeatForever(autoreverses: true)
            }
        }
        .onTapGesture(count: 1) {
            onSelect()
        }
        .rotation3DEffect(
            .degrees(0),
            axis: (x: 0, y: 1, z: 0)
        )
        .glassEffect(.liquid, alignment: .center)
    }
    
    /// Color gradient based on confidence level.
    private func confidenceColor(for confidence: Double) -> [Color] {
        switch confidence {
        case 0.9...:
            return [.green, .green.opacity(0.3)]
        case 0.85...:
            return [.green.opacity(0.8), .yellow.opacity(0.3)]
        case 0.7...:
            return [.yellow, .orange.opacity(0.3)]
        default:
            return [.red, .orange.opacity(0.3)]
        }
    }
}

/// Control panel with sliders for brightness and color temperature.
/// Anchored to a detected fixture via ViewAttachmentComponent.
struct HueControlPanel: View {
    
    let fixture: TrackedFixture
    let hueClient: HueClient
    let stateStream: HueStateStream
    
    @State private var brightnessValue: Double = 50
    @State private var colorTempValue: Double = 4000
    @State private var isOn: Bool = true
    
    /// Current light state from the stream.
    private var currentLight: HueLightResource? {
        if let lightId = fixture.hudEntityID {
            // Find the corresponding light
            return stateStream.lights.first { light in
                light.id == fixture.id.uuidString
            }
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
                        if let groupId = stateStream.selectedGroupId {
                            Task {
                                try await hueClient.togglePower(groupId: groupId, on: newValue)
                            }
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
                        if !changed, let groupId = stateStream.selectedGroupId {
                            Task {
                                try await hueClient.setBrightness(
                                    groupId: groupId,
                                    brightness: Int(brightnessValue)
                                )
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
                        if !changed, let groupId = stateStream.selectedGroupId {
                            let mireds = Int(1000000.0 / colorTempValue)
                            Task {
                                try await hueClient.setColorTemperature(
                                    groupId: groupId,
                                    mireds: mireds
                                )
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
}

/// Scene recall button - triggered by SpatialTapGesture on the reticle.
struct SceneRecallButton: View {
    
    let scenes: [HueSceneResource]
    let groupId: String
    let hueClient: HueClient
    let onRecall: (String) -> Void
    
    var body: some View {
        Menu {
            ForEach(scenes) { scene in
                Button {
                    Task {
                        try await hueClient.recallScene(
                            groupId: groupId,
                            sceneId: scene.id
                        )
                        onRecall(scene.id)
                    }
                } label: {
                    Label(
                        scene.metadata.name ?? scene.id,
                        systemImage: "sparkles"
                    )
                }
            }
        } label: {
            Label("Scenes", systemImage: "light.beacon.min")
                .font(.caption)
        }
        .glassEffect(.liquid, alignment: .center)
    }
}
