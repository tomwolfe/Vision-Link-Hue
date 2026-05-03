import SwiftUI
import RealityKit
import ARKit

/// SwiftUI view that manages an ARKit session using RealityKit 2026's
/// `RealityView` for entity management with unified view attachments.
/// Uses the native RealityKit 2026 ViewAttachmentComponent(rootView:)
/// API for automatic SwiftUI view lifecycle management and @Observable-driven
/// entity updates.
struct ARViewContainer: View {
    
    @ObservedObject var sessionManager: ARSessionManager
    let onFrameUpdate: (ARFrame) -> Void
    let onARViewReady: (ARView) -> Void
    
    @State private var arViewRef: ARView?
    
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
            
            // RealityView overlay for SwiftUI-rendered HUD entities.
            // Fixture HUDs are created directly on RealityKit entities using
            // the native ViewAttachmentComponent(rootView:) API, so no
            // additional RealityViewContent registration is needed.
            RealityView { content, attachments in
                guard let arView = arViewRef else { return }
                
                // Add a root entity for HUD overlays
                let hudRoot = Entity()
                hudRoot.name = "HUDRoot"
                arView.scene.addEntity(hudRoot)
            } update: { content, attachments in
                // Fixture HUD entities are managed directly via
                // ViewAttachmentComponent(rootView:) on each entity.
                // No additional update logic needed.
            }
        }
    }
}

/// UIViewRepresentable wrapper for ARKit's ARView.
/// Uses the coordinator pattern for frame callbacks.
struct ARViewRepresentable: UIViewRepresentable {
    
    let onFrameUpdate: (ARFrame) -> Void
    let onARViewReady: (ARView) -> Void
    
    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)
        let session = ARSession()
        session.delegate = context.coordinator
        session.run(ARWorldTrackingConfiguration())
        
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
