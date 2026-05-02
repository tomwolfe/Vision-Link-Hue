import Foundation
import Combine

/// Severity levels for application errors.
enum AppErrorSeverity: Comparable {
    case informational
    case warning
    case error
    case critical
}

/// Unified error type for the application.
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
    
    /// Deprecated: use `activeErrors` instead.
    @Published var errorMessage: String?
    
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
