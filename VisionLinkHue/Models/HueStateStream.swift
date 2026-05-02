import Foundation
import Combine

/// Severity levels for application errors, used to prioritize UI feedback.
/// Ordered from least to most severe for `Comparable` conformance.
enum AppErrorSeverity: Comparable {
    /// Informational messages that auto-dismiss after 3 seconds.
    case informational
    /// Warnings about non-critical issues (e.g., no bridge found).
    case warning
    /// Errors requiring user attention (e.g., API failures).
    case error
    /// Critical errors that may prevent the app from functioning.
    case critical
}

/// Unified error type for the application, wrapping any `Error` with
/// severity classification, source attribution, and display formatting.
struct AppError: Identifiable, LocalizedError {
    let id: UUID
    let error: any Error
    let severity: AppErrorSeverity
    let source: String
    let timestamp: Date
    
    init(error: any Error, severity: AppErrorSeverity = .error, source: String = "unknown") {
        self.id = UUID()
        self.error = error
        self.severity = severity
        self.source = source
        self.timestamp = Date()
    }
    
    var errorDescription: String? {
        error.localizedDescription
    }
    
    var displayMessage: String {
        switch severity {
        case .informational:
            return "ℹ️ \(error.localizedDescription)"
        case .warning:
            return "⚠️ \(error.localizedDescription)"
        case .error:
            return "❌ \(error.localizedDescription)"
        case .critical:
            return "🚨 \(error.localizedDescription)"
        }
    }
}

/// Centralized state manager for Hue bridge data and connection status.
/// Publishes lights, scenes, groups, connection status, and errors via Combine.
final class HueStateStream: ObservableObject {
    
    @Published private(set) var lights: [HueLightResource] = []
    @Published private(set) var scenes: [HueSceneResource] = []
    @Published private(set) var groups: [BridgeGroup] = []
    
    @Published var isConnected: Bool = false
    @Published var bridgeConfig: BridgeConfig?
    
    /// Active error queue for toast/banner display.
    @Published var activeErrors: [AppError] = []
    
    /// Mapping from local fixture UUID to Hue bridge light ID.
    /// Populated via tap-to-link in the HUD.
    @Published private(set) var fixtureLightMapping: [UUID: String] = [:]
    
    func setIsConnected(_ connected: Bool) {
        isConnected = connected
    }
    
    /// UUID of the currently selected light group for HUD anchoring.
    @Published var selectedGroupId: String?
    
    private let cancellables = Set<AnyCancellable>()
    
    /// Process a partial resource update from the SSE stream.
    func applyUpdate(_ update: ResourceUpdate) {
        if let lights = update.lights {
            self.lights = merge(existing: self.lights, incoming: lights)
        }
        
        if let scenes = update.scenes {
            self.scenes = merge(existing: self.scenes, incoming: scenes)
        }
        
        if let groups = update.groups {
            self.groups = merge(existing: self.groups, incoming: groups)
        }
    }
    
    /// Merge incoming identifiable resources into the existing collection,
    /// replacing entries with matching IDs and appending new ones.
    private func merge<T: Identifiable & Equatable>(existing: [T], incoming: [T]) -> [T]
    where T.ID == String {
        var result = existing
        for item in incoming {
            if let idx = result.firstIndex(where: { $0.id == item.id }) {
                result[idx] = item
            } else {
                result.append(item)
            }
        }
        return result
    }
    
    /// Resolve a light by its bridge-assigned ID.
    func light(by id: String) -> HueLightResource? {
        lights.first { $0.id == id }
    }
    
    /// Resolve a light that is mapped to a local fixture UUID.
    func light(forFixture fixtureId: UUID) -> HueLightResource? {
        guard let lightId = fixtureLightMapping[fixtureId] else { return nil }
        return light(by: lightId)
    }
    
    /// Link a local fixture UUID to a Hue bridge light ID.
    func linkFixture(_ fixtureId: UUID, toLight lightId: String) {
        fixtureLightMapping[fixtureId] = lightId
    }
    
    /// Unlink a local fixture from its mapped Hue light.
    func unlinkFixture(_ fixtureId: UUID) {
        fixtureLightMapping.removeValue(forKey: fixtureId)
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
    
    /// Report an error to the active error queue for UI display.
    func reportError(_ error: any Error, severity: AppErrorSeverity = .error, source: String) {
        let appError = AppError(error: error, severity: severity, source: source)
        activeErrors.append(appError)
        
        // Auto-clear informational errors after 3 seconds
        if severity == .informational {
            Task {
                try? await Task.sleep(for: .seconds(3))
                self.activeErrors.removeAll { $0.id == appError.id }
            }
        }
    }
    
    /// Dismiss a specific error from the queue.
    func dismissError(_ error: AppError) {
        activeErrors.removeAll { $0.id == error.id }
    }
    
    /// Clear all active errors.
    func clearErrors() {
        activeErrors.removeAll()
    }
}
