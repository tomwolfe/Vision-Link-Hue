import SwiftUI
import RealityKit
import ARKit

/// Scene picker for recalling lighting scenes.
struct ScenePickerView: View {
    
    let scenes: [HueSceneResource]
    let groupId: String
    let hueClient: HueClient
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            List {
                if scenes.isEmpty {
                    Text("No scenes available")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(scenes) { scene in
                        Button {
                            Task {
                                do {
                                    try await hueClient.recallScene(
                                        groupId: groupId,
                                        sceneId: scene.id
                                    )
                                } catch {
                                    // Errors surface via hueClient.lastError
                                    // and SSE event stream reconnection.
                                    print("Scene recall failed: \(error.localizedDescription)")
                                }
                            }
                        } label: {
                            HStack {
                                Image(systemName: "sparkles")
                                    .foregroundStyle(.yellow)
                                Text(scene.metadata.name ?? scene.id)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Scenes")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}
