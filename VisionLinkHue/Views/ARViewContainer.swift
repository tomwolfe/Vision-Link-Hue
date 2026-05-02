import SwiftUI
import RealityKit
import ARKit

/// Container that bridges ARKit's ARView with SwiftUI's RealityView.
/// Handles frame callbacks and feeds them to the DetectionEngine.
struct ARViewContainer: UIViewRepresentable {
    
    let sessionManager: ARSessionManager
    let onFrameUpdate: (ARFrame) -> Void
    
    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)
        arView.session.delegate = context.coordinator
        arView.session.delegateQueue = .main
        
        // Enable world reconstruction visualization (debug)
        arView.debugOptions = [.showAnchorLocators]
        
        // Configure for best performance on A18 chip
        arView.preferredFramesPerSecond = 60
        arView.preferredStereoRenderingMode = .mono
        
        return arView
    }
    
    func updateUIView(_ uiView: ARView, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    @MainActor
    final class Coordinator: NSObject, ARSessionDelegate {
        
        let parent: ARViewContainer
        
        init(_ parent: ARViewContainer) {
            self.parent = parent
        }
        
        func session(_ session: ARSession, didUpdate frame: ARFrame) {
            parent.onFrameUpdate(frame)
        }
    }
}

/// Main AR view that combines RealityKit rendering with SwiftUI overlays.
struct ARViewContainerView: View {
    
    @ObservedObject var sessionManager: ARSessionManager
    @ObservedObject var hueClient: HueClient
    @ObservedObject var stateStream: HueStateStream
    @StateObject private var detectionEngine = DetectionEngine()
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // AR background via ARView
                ARViewContainer(
                    sessionManager: sessionManager,
                    onFrameUpdate: { frame in
                        Task {
                            await sessionManager.didUpdateFrame(frame)
                        }
                    }
                )
                .ignoresSafeArea()
                
                // 3D overlay layer for RealityKit entities
                RealityView { content in
                    // Add 3D reticles for each anchored fixture
                    for fixture in sessionManager.anchoredFixtures {
                        let reticle = Entity() {
                            ModelEntity(
                                mesh: .generateSphere(radius: 0.02),
                                materials: [
                                    SimpleMaterial(
                                        color: .white,
                                        isMetallic: false,
                                        roughness: 0.3
                                    )
                                ]
                            )
                        }
                        reticle.position = fixture.position
                        reticle.orientation = fixture.orientation
                        
                        content.add(reticle)
                    }
                }
                .cameraStartTransform(.identity)
                
                // 2D HUD overlay (always faces camera)
                HUDOverlay(
                    sessionManager: sessionManager,
                    detectionEngine: detectionEngine,
                    hueClient: hueClient,
                    stateStream: stateStream,
                    frameSize: geometry.size
                )
                .allowsHitTesting(true)
            }
        }
        .onAppear {
            Task {
                await sessionManager.configureAndStart(in: /* need ARView */)
            }
        }
    }
}

/// 2D HUD overlay with detection status and controls.
struct HUDOverlay: View {
    
    @ObservedObject var sessionManager: ARSessionManager
    @ObservedObject var detectionEngine: DetectionEngine
    @ObservedObject var hueClient: HueClient
    @ObservedObject var stateStream: HueStateStream
    let frameSize: CGSize
    
    @State private var showBridgeSetup: Bool = false
    @State private var showScenes: Bool = false
    @State private var selectedFixtureId: UUID?
    
    var body: some View {
        VStack {
            // Top bar: status + bridge connection
            HStack {
                // Connection status
                HStack(spacing: 6) {
                    Circle()
                        .fill(hueClient.is_connected ? .green : .red)
                        .frame(width: 8, height: 8)
                    
                    Text(hueClient.is_connected ? "Bridge Connected" : "No Bridge")
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
                        hueClient: hueClient
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Rectangle())
            .glassEffect(.liquid, alignment: .center)
            
            Spacer()
            
            // Bottom bar: bridge setup + instructions
            if !hueClient.is_connected {
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
                .glassEffect(.liquid, alignment: .center)
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
                            .task {
                                detectionEngine.start()
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
                .glassEffect(.liquid, alignment: .center)
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

/// Bridge discovery and connection sheet.
struct BridgeDiscoveryView: View {
    
    @ObservedObject var hueClient: HueClient
    @ObservedObject var stateStream: HueStateStream
    @Environment(\.dismiss) private var dismiss
    
    @State private var bridges: [BridgeInfo] = []
    @State private var isDiscovering: Bool = false
    @State private var isLoading: Bool = false
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if isDiscovering {
                    ProgressView("Discovering bridges...")
                        .padding()
                } else if bridges.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "wifi")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        
                        Text("No bridges found")
                            .font(.headline)
                        
                        Text("Make sure your Hue bridge is powered on and connected to the same network.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        
                        Button("Try Again") {
                            Task { await discover() }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.blue)
                    }
                    .padding()
                } else {
                    List(bridges) { bridge in
                        Button {
                            Task {
                                isLoading = true
                                await hueClient.connect(to: bridge)
                                isLoading = false
                            }
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(bridge.name)
                                        .font(.headline)
                                    Text("\(bridge.ip):\(bridge.port)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                
                                Spacer()
                                
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                
                if let error = hueClient.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.horizontal)
                }
            }
            .navigationTitle("Hue Bridge")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task {
                if bridges.isEmpty {
                    await discover()
                }
            }
        }
    }
    
    private func discover() async {
        isDiscovering = true
        bridges = await hueClient.discoverBridges()
        isDiscovering = false
    }
}

/// Scene picker for recalling lighting scenes.
struct ScenePickerView: View {
    
    let scenes: [HueSceneResource]
    let groupId: String
    let hueClient: HueClient
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            List {
                if scenes.isEmpty {
                    Text("No scenes available")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(scenes) { scene in
                        Button {
                            Task {
                                try await hueClient.recallScene(
                                    groupId: groupId,
                                    sceneId: scene.id
                                )
                            }
                        } label: {
                            HStack {
                                Image(systemName: "sparkles")
                                    .foregroundStyle(.yellow)
                                Text(scene.metadata.name ?? scene.id)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Scenes")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}
