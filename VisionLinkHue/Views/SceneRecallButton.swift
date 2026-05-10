import SwiftUI
import RealityKit
import simd

/// Scene recall button - triggered by SpatialTapGesture on the reticle.
struct SceneRecallButton: View {
    
    let scenes: [HueSceneResource]
    let groupId: String
    let hueClient: HueClient
    let stateStream: HueStateStream
    let onRecall: (String) -> Void
    
    var body: some View {
        Menu {
            ForEach(scenes) { scene in
                Button {
                    Task {
                        do {
                            try await hueClient.recallScene(
                                groupId: groupId,
                                sceneId: scene.id
                            )
                        } catch {
                            stateStream.reportError(error, severity: .error, source: "SceneRecallButton")
                        }
                        onRecall(scene.id)
                    }
                } label: {
                    Label(
                        scene.metadata.name ?? scene.id,
                        systemImage: "sparkles"
                    )
                }
            }
        } label: {
            Label("Scenes", systemImage: "light.beacon.min")
                .font(.caption)
        }
        .accessibilityLabel(Text("Scene recall"))
        .accessibilityHint(Text("Open menu to recall lighting scenes"))
    }
}
