import SwiftUI
import RealityKit
import ARKit

/// Container that bridges ARKit's ARView with SwiftUI's RealityView.
/// Handles frame callbacks and feeds them to the DetectionEngine.
struct ARViewContainer: UIViewRepresentable {
    
    let sessionManager: ARSessionManager
    let onFrameUpdate: (ARFrame) -> Void
    let onARViewReady: (ARView) -> Void
    
    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)
        arView.session.delegate = context.coordinator
        arView.session.delegateQueue = .main
        
        arView.preferredFramesPerSecond = 60
        arView.preferredStereoRenderingMode = .mono
        
        onARViewReady(arView)
        
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
