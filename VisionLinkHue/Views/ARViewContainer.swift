import SwiftUI
import RealityKit
import ARKit

/// SwiftUI view that manages an ARKit session using RealityKit 2026's
/// `RealityView` for entity management with unified view attachments.
/// Uses the native RealityKit 2026 ViewAttachmentComponent API for
/// automatic SwiftUI view lifecycle management and @Observable-driven
/// entity updates.
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
            // using the RealityKit 2026 native ViewAttachmentComponent API
            RealityView { content in
                guard let arView = arViewRef else { return }
                
                // Add a root entity for HUD overlays
                let hudRoot = Entity()
                hudRoot.name = "HUDRoot"
                arView.scene.addEntity(hudRoot)
                
                // Register with session manager for unified view attachment
                sessionManager.setRealityViewContent(content)
            } update: { content, entities in
                // RealityKit 2026 unified attachment updates are handled
                // automatically through @Observable entity property tracking
            } content: {
                RealityViewContent { attachments in
                    // Register attachment handlers for fixture HUDs
                    // using the RealityKit 2026 native ViewAttachmentComponent
                    for fixture in sessionManager.trackedFixtures {
                        attachments.add(fixture.hudEntityID.map { Entity($0) })
                    }
                }
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
