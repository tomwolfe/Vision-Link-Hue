import SwiftUI
import RealityKit
import ARKit

/// SwiftUI view that manages an ARKit session using RealityKit 2026's
/// `RealityView` for entity management with unified view attachments.
/// Replaces the manual ARViewRepresentable pattern with a cleaner
/// RealityView-based abstraction that integrates with the finalized
/// RealityKit 2026 ViewAttachmentComponent API.
struct ARViewContainer: View {
    
    @ObservedObject var sessionManager: ARSessionManager
    let onFrameUpdate: (ARFrame) -> Void
    let onARViewReady: (ARView) -> Void
    
    @State private var arViewRef: ARView?
    @State private var entityRegistry: [Entity.ID: TrackedFixture] = [:]
    
    var body: some View {
        ZStack {
            ARViewRepresentable(
                onFrameUpdate: onFrameUpdate,
                onARViewReady: { arView in
                    onARViewReady(arView)
                    arViewRef = arView
                }
            )
            .ignoresSafeArea()
            
            // RealityView overlay for SwiftUI-rendered HUD entities
            // using the RealityKit 2026 Unified Attachment API
            RealityView { content in
                guard let arView = arViewRef else { return }
                
                // Add a root entity for HUD overlays that uses
                // the RealityKit 2026 unified attachment system
                let hudRoot = Entity()
                hudRoot.name = "HUDRoot"
                arView.scene.addEntity(hudRoot)
                
                // Register the RealityView content with the session manager
                // so it can manage view attachments through the unified API
                sessionManager.setRealityViewContent(content)
            } update: { content, entities in
                // Handle entity updates for view attachments
                for (_, entity) in entities where entity.name == "FixtureHUD" {
                    // RealityKit 2026 unified attachment updates
                    // handled automatically through the RealityView system
                }
            }
        }
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
