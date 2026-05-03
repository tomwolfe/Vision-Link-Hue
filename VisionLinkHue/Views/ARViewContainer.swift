import SwiftUI
import RealityKit
import ARKit

/// SwiftUI view that manages an ARKit session using RealityKit.
/// Provides a single ARView with frame callbacks for the detection pipeline.
/// HUD entities are added directly via ARView.content for entity management.
struct ARViewContainer: View {
    
    @Bindable var sessionManager: ARSessionManager
    let onFrameUpdate: (ARFrame) -> Void
    let onARViewReady: (ARView) -> Void
    
    var body: some View {
        ARViewRepresentable(
            sessionManager: sessionManager,
            onFrameUpdate: onFrameUpdate,
            onARViewReady: onARViewReady
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
    let onARViewReady: (ARView) -> Void
    
    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)
        
        arView.session.delegate = context.coordinator
        
        self.onARViewReady(arView)
        
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
        Coordinator(self)
    }
    
    final class Coordinator: NSObject, ARSessionDelegate {
        let parent: ARViewRepresentable
        var isSessionRunning: Bool = false
        
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
