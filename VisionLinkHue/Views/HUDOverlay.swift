import SwiftUI
import RealityKit
import ARKit

/// 2D HUD overlay with detection status and controls.
struct HUDOverlay: View {
    
    let sessionManager: ARSessionManager
    let detectionEngine: DetectionEngine
    let hueClient: HueClient
    let stateStream: HueStateStream
    let frameSize: CGSize
    
    @State private var showBridgeSetup: Bool = false
    @State private var showScenes: Bool = false
    @State private var selectedFixtureId: UUID?
    @State private var depthOffsetMeters: Float = 0.0
    
    /// Minimum and maximum depth offset range in meters.
    private let minDepthOffset: Float = -3.0
    private let maxDepthOffset: Float = 3.0
    
    var body: some View {
        VStack {
            // Top bar: status + bridge connection
            HStack {
                // Connection status
                HStack(spacing: 6) {
                    Circle()
                        .fill(stateStream.isConnected ? .green : .red)
                        .frame(width: 8, height: 8)
                    
                    Text(stateStream.isConnected ? "Bridge Connected" : "No Bridge")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                // AI status
                HStack(spacing: 6) {
                    Circle()
                        .fill(detectionEngine.isRunning ? .blue : .gray)
                        .frame(width: 8, height: 8)
                    
                    Text("AI \(detectionEngine.lastDetections.count)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                // Settings / Scene recall
                Button {
                    showScenes.toggle()
                } label: {
                    Image(systemName: "light.beacon.min")
                        .foregroundStyle(.secondary)
                }
                .sheet(isPresented: $showScenes) {
                    ScenePickerView(
                        scenes: stateStream.scenes,
                        groupId: stateStream.selectedGroupId ?? "",
                        hueClient: hueClient,
                        stateStream: stateStream
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Rectangle())
            
            Spacer()
            
            // Bottom bar: bridge setup + instructions
            if !stateStream.isConnected {
                VStack(spacing: 12) {
                    Text("Connect to Hue Bridge")
                        .font(.headline)
                    
                    Button("Discover Bridge") {
                        showBridgeSetup = true
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                    
                    Text("Press the link button on your Hue bridge first")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding()
                .background(.ultraThinMaterial, in: Rectangle())
                .padding(.bottom, 32)
            } else {
                // Detection instructions
                VStack(spacing: 8) {
                    if detectionEngine.isRunning {
                        Text("Point camera at lighting fixtures")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Scanning...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    
                    // Depth offset slider for non-LiDAR devices
                    if let fixtureId = selectedFixtureId,
                       let fixture = sessionManager.trackedFixtures.first(where: { $0.id == fixtureId }) {
                        VStack(spacing: 4) {
                            HStack {
                                Text("Depth Adjust")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(String(format: "%.1fm", fixture.depthOffsetMeters))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            
                            Slider(
                                value: Binding(
                                    get: { fixture.depthOffsetMeters },
                                    set: { newValue in
                                        sessionManager.adjustDepthOffset(
                                            for: fixtureId,
                                            offset: newValue
                                        )
                                    }
                                ),
                                in: minDepthOffset...maxDepthOffset
                            )
                            .labelsHidden()
                        }
                    }
                    
                    // Detection latency indicator
                    if detectionEngine.inferenceLatencyMs > 200 {
                        HStack {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                            Text("Slow inference: \(Int(detectionEngine.inferenceLatencyMs))ms")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Rectangle())
                .padding(.bottom, 32)
            }
        }
        .sheet(isPresented: $showBridgeSetup) {
            BridgeDiscoveryView(
                hueClient: hueClient,
                stateStream: stateStream
            )
        }
    }
}
