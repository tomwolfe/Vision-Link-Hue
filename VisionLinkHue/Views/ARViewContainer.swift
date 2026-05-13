import SwiftUI
import RealityKit
import ARKit
import os

/// SwiftUI view that manages an ARKit session using RealityKit.
/// Provides a single ARView with frame callbacks for the detection pipeline.
/// HUD entities are added directly via ARView.content for entity management.
struct ARViewContainer: View {
    
    @Bindable var sessionManager: ARSessionManager
    let detectionEngine: DetectionEngine
    let hueClient: HueClient
    let stateStream: HueStateStream
    let spatialProjector: SpatialProjector
    
    var body: some View {
        ARViewRepresentable(
            sessionManager: sessionManager,
            detectionEngine: detectionEngine,
            hueClient: hueClient,
            stateStream: stateStream,
            spatialProjector: spatialProjector
        )
        .ignoresSafeArea()
    }
}

/// UIViewRepresentable wrapper for ARKit's ARView.
/// Manages the AR session lifecycle and provides frame callbacks
/// through the coordinator pattern.
struct ARViewRepresentable: UIViewRepresentable {
    
    @Bindable var sessionManager: ARSessionManager
    let detectionEngine: DetectionEngine
    let hueClient: HueClient
    let stateStream: HueStateStream
    let spatialProjector: SpatialProjector
    
    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)
        
        arView.session.delegate = context.coordinator
        
        context.coordinator.detectionEngine = detectionEngine
        context.coordinator.hueClient = hueClient
        context.coordinator.stateStream = stateStream
        context.coordinator.spatialProjector = spatialProjector
        context.coordinator.arView = arView
        context.coordinator.sessionManager = sessionManager
        
        Task { @MainActor in await sessionManager.configureAndStart(in: arView) }
        
        return arView
    }
    
    func updateUIView(_ arView: ARView, context: Context) {
        if sessionManager.isSessionActive {
            if !context.coordinator.isSessionRunning {
                let configuration = ARWorldTrackingConfiguration().configuredWithEnvironment()
                arView.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
                context.coordinator.isSessionRunning = true
            }
        } else {
            arView.session.pause()
            context.coordinator.isSessionRunning = false
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    final class Coordinator: NSObject, ARSessionDelegate {
        var isSessionRunning: Bool = false
        var detectionEngine: DetectionEngine?
        var hueClient: HueClient?
        var stateStream: HueStateStream?
        var spatialProjector: SpatialProjector?
        var arView: ARView?
        var sessionManager: ARSessionManager?
        
        func session(_ session: ARSession, didUpdate frame: ARFrame) {
            guard let sessionManager else { return }
            Task {
                await sessionManager.didUpdateFrame(frame)
            }
        }
    }
}
