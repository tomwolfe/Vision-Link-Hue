import SwiftUI
import RealityKit
import ARKit

/// SwiftUI view that manages an ARKit session and provides frame callbacks.
/// Replaces the UIKit-bridged `ARViewContainer` with a cleaner abstraction
/// that integrates better with SwiftUI's `RealityView` for entity management.
struct ARSessionView: View {
    
    @ObservedObject var sessionManager: ARSessionManager
    let onFrameUpdate: (ARFrame) -> Void
    let onARViewReady: (ARView) -> Void
    
    @State private var arViewRef: ARView?
    
    var body: some View {
        ARViewRepresentable(
            onFrameUpdate: onFrameUpdate,
            onARViewReady: { arView in
                onARViewReady(arView)
                arViewRef = arView
            }
        )
        .ignoresSafeArea()
    }
}

/// UIViewRepresentable wrapper for ARKit's ARView.
/// Minimal coordinator pattern for frame callbacks.
struct ARViewRepresentable: UIViewRepresentable {
    
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
        let parent: ARViewRepresentable
        
        init(_ parent: ARViewRepresentable) {
            self.parent = parent
        }
        
        func session(_ session: ARSession, didUpdate frame: ARFrame) {
            parent.onFrameUpdate(frame)
        }
    }
}
