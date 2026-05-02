import Foundation
import Combine

/// Typed stream of Hue state changes from the SSE event stream.
@MainActor
final class HueStateStream: ObservableObject {
    
    @Published private(set) var lights: [HueLightResource] = []
    @Published private(set) var scenes: [HueSceneResource] = []
    @Published private(set) var groups: [BridgeGroup] = []
    
    @Published var isConnected: Bool = false
    @Published var bridgeConfig: BridgeConfig?
    @Published var errorMessage: String?
    
    /// UUID of the currently selected light group for HUD anchoring.
    @Published var selectedGroupId: String?
    
    private let cancellables = Set<AnyCancellable>()
    
    /// Process a partial resource update from the SSE stream.
    func applyUpdate(_ update: ResourceUpdate) {
        if let lights = update.lights {
            let existingDict = Dictionary(lights.map { ($0.id, $0) }, uniquingKeysWith: { new, _ in new })
            for id in update.lights.map(\.id) where !existingDict.keys.contains(id) {
                // new light
            }
            var merged = self.lights
            for light in lights {
                if let idx = merged.firstIndex(where: { $0.id == light.id }) {
                    merged[idx] = light
                } else {
                    merged.append(light)
                }
            }
            self.lights = merged
        }
        
        if let scenes = update.scenes {
            var merged = self.scenes
            for scene in scenes {
                if let idx = merged.firstIndex(where: { $0.id == scene.id }) {
                    merged[idx] = scene
                } else {
                    merged.append(scene)
                }
            }
            self.scenes = merged
        }
        
        if let groups = update.groups {
            var merged = self.groups
            for group in groups {
                if let idx = merged.firstIndex(where: { $0.id == group.id }) {
                    merged[idx] = group
                } else {
                    merged.append(group)
                }
            }
            self.groups = merged
        }
    }
    
    /// Resolve a light by its ID.
    func light(by id: String) -> HueLightResource? {
        lights.first { $0.id == id }
    }
    
    /// Resolve a scene by its ID.
    func scene(by id: String) -> HueSceneResource? {
        scenes.first { $0.id == id }
    }
    
    /// Get all lights belonging to a group.
    func lights(inGroup groupId: String) -> [HueLightResource] {
        guard let group = groups.first(where: { $0.id == groupId }) else { return [] }
        return group.lights.compactMap { light(by: $0) }
    }
}
