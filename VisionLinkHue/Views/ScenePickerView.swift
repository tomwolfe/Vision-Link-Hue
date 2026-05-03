import SwiftUI
import RealityKit
import ARKit
import os

/// Scene picker for recalling lighting scenes.
struct ScenePickerView: View {
    
    private static let logger = Logger(
        subsystem: "com.tomwolfe.visionlinkhue",
        category: "ScenePickerView"
    )
    
    let scenes: [HueSceneResource]
    let groupId: String
    let hueClient: HueClient
    let stateStream: HueStateStream?
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
                                    Self.logger.error("Scene recall failed: \(error.localizedDescription)")
                                    await stateStream?.reportError(error, severity: .error, source: "ScenePickerView.recall")
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
