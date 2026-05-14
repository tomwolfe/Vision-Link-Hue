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
struct ARViewRepresentable: UIViewRepresentable, Sendable {
    
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
        private var processingTask: Task<Void, Never>?
    }
}

extension ARViewRepresentable.Coordinator {
    @MainActor
    func session(_ session: ARSession, didUpdate frame: ARFrame) async {
            guard let sessionManager else { return }
            processingTask?.cancel()
            
            // Extract all data synchronously to release the frame reference promptly.
            // The frame itself is released as soon as this method returns.
            let imageData = frame.imageBuffer
            let timestamp = frame.timestamp
            let displayTransform = frame.displayTransform(
                for: .portrait,
                viewportSize: CGSize(
                    width: CGFloat(CVPixelBufferGetWidth(frame.imageBuffer)),
                    height: CGFloat(CVPixelBufferGetHeight(frame.imageBuffer))
                )
            )
            let cameraTransform = frame.camera.transform
            
            processingTask = Task {
                sessionManager.didUpdateFrame(
                    imageBuffer: imageData,
                    timestamp: timestamp,
                    displayTransform: displayTransform,
                    cameraTransform: cameraTransform
                )
            }
        }
    }
