import SwiftUI
import RealityKit
import ARKit

/// SwiftUI view that manages an ARKit session using RealityKit.
/// Provides a single ARView with frame callbacks for the detection pipeline.
/// HUD entities are added directly via ARView.content for entity management.
struct ARViewContainer: View {
    
    @Bindable var sessionManager: ARSessionManager
    let onFrameUpdate: (ARFrame) -> Void
    let onARViewReady: (ARView) -> Void = { _ in }
    
    var body: some View {
        ARViewRepresentable(
            sessionManager: sessionManager,
            onFrameUpdate: onFrameUpdate
        )
        .ignoresSafeArea()
    }
}

/// UIViewRepresentable wrapper for ARKit's ARView.
/// Manages the AR session lifecycle and provides frame callbacks
/// through the coordinator pattern.
struct ARViewRepresentable: UIViewRepresentable {
    
    @Bindable var sessionManager: ARSessionManager
    let onFrameUpdate: (ARFrame) -> Void
    
    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)
        
        let configuration = ARWorldTrackingConfiguration()
        #if !targetEnvironment(simulator)
        configuration.worldReconstructionMode = ARWorldTrackingConfiguration.WorldReconstructionMode.automatic
        configuration.planeDetection = [.horizontal, .vertical]
        configuration.lightEstimation = .automatic
        #else
        configuration.planeDetection = [.horizontal, .vertical]
        #endif
        
        arView.session.run(configuration)
        arView.session.delegate = context.coordinator
        
        parent.onARViewReady(arView)
        
        return arView
    }
    
    func updateUIView(_ arView: ARView, context: Context) {
        // Pass high-level session commands from ARSessionManager
        // to the ARView's session
        if !sessionManager.isSessionActive {
            arView.session.pause()
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    final class Coordinator: NSObject, ARSessionDelegate {
        let parent: ARViewRepresentable
        
        init(_ parent: ARViewRepresentable) {
            self.parent = parent
        }
        
        func session(_ session: ARSession, didUpdate frame: ARFrame) {
            let parentRef = parent
            DispatchQueue.main.async {
                parentRef.onFrameUpdate(frame)
            }
        }
    }
}
