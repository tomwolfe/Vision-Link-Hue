import Foundation
import simd

// MARK: - Error Severity Levels

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

// MARK: - App Error Type

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

// MARK: - App Notification System Actor

/// Dedicated actor for centralized error notification handling.
/// Prevents main-thread hangs during SSE reconnection bursts by
/// batching and deduplicating errors before dispatching to the UI.
///
/// The actor serializes error processing and applies rate-limiting
/// to prevent notification flooding during rapid reconnection cycles.
actor AppNotificationSystem {
    
    /// Maximum number of concurrent active notifications.
    private static let maxActiveNotifications = 5
    
    /// Minimum time between notifications of the same source (seconds).
    private static let sourceCooldownInterval: TimeInterval = 2.0
    
    /// Currently active notifications.
    private var activeNotifications: [AppError] = []
    
    /// Last notification time per source for rate limiting.
    private var lastNotificationTimeBySource: [String: Date] = [:]
    
    /// Notification event publisher for UI consumption.
    var onNotification: (@Sendable ([AppError]) -> Void)?
    
    /// Set the notification event handler.
    func setNotificationHandler(_ handler: @escaping @Sendable ([AppError]) -> Void) {
        onNotification = handler
    }
    
    /// Number of active notifications.
    var notificationCount: Int {
        activeNotifications.count
    }
    
    /// Get all active notifications.
    func getActiveNotifications() -> [AppError] {
        activeNotifications
    }
    
    /// Enqueue an error notification with deduplication and rate limiting.
    func enqueueNotification(_ error: any Error, severity: AppErrorSeverity = .error, source: String) {
        let appError = AppError(error: error, severity: severity, source: source)
        
        // Skip if we already have this exact error from the same source
        // within the cooldown period
        if let lastTime = lastNotificationTimeBySource[source],
           Date().timeIntervalSince(lastTime) < AppNotificationSystem.sourceCooldownInterval {
            return
        }
        
        // Skip if we're at the maximum notification limit and this is
        // not a critical error
        if activeNotifications.count >= AppNotificationSystem.maxActiveNotifications,
           severity != .critical {
            return
        }
        
        // Remove duplicate errors from the same source
        activeNotifications.removeAll { $0.source == source && $0.error._domain == (error as NSError).domain }
        
        activeNotifications.append(appError)
        lastNotificationTimeBySource[source] = Date()
        
        // Notify UI of the updated notification list
        onNotification?(activeNotifications)
        
        // Auto-dismiss informational errors after 3 seconds
        if severity == .informational {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                await self?.dismissNotification(withId: appError.id)
            }
        }
    }
    
    /// Dismiss a specific notification by ID.
    func dismissNotification(withId id: UUID) {
        activeNotifications.removeAll { $0.id == id }
        onNotification?(activeNotifications)
    }
    
    /// Clear all active notifications.
    func clearAllNotifications() {
        activeNotifications.removeAll()
        onNotification?(activeNotifications)
    }
    
    /// Get notifications for a specific source.
    func notifications(fromSource source: String) -> [AppError] {
        activeNotifications.filter { $0.source == source }
    }
}

// MARK: - Centralized State Manager

/// Centralized state manager for Hue bridge data and connection status.
/// Uses the `@Observable` macro for granular dependency tracking without
/// Combine's overhead of full-view re-renders.
///
/// Delegates error notification handling to the `AppNotificationSystem`
/// actor to prevent main-thread hangs during SSE reconnection bursts.
@Observable
@MainActor
final class HueStateStream: Sendable {
    
    private(set) var lights: [HueLightResource] = []
    private(set) var scenes: [HueSceneResource] = []
    private(set) var groups: [BridgeGroup] = []
    
    var isConnected: Bool = false
    var bridgeConfig: BridgeConfig?
    
    /// Active error queue for toast/banner display.
    /// Backed by the AppNotificationSystem actor for thread-safe processing.
    private(set) var activeErrors: [AppError] = []
    
    /// Mapping from local fixture UUID to Hue bridge light ID.
    /// Populated via tap-to-link in the HUD.
    /// Backed by SwiftData for atomic spatial coordinate persistence.
    private(set) var fixtureLightMapping: [UUID: String] = [:]
    
    /// Dedicated actor for error notification handling.
    /// Prevents main-thread hangs during SSE reconnection bursts.
    private let notificationSystem = AppNotificationSystem()
    
    private let persistence: FixturePersistence
    
    init(persistence: FixturePersistence) {
        self.persistence = persistence
        loadPersistedState()
        configure()
    }
    
    func configure() {
        Task { [notificationSystem] in
            await notificationSystem.setNotificationHandler { [weak self] notifications in
                Task { @MainActor [weak self] in
                    self?.activeErrors = notifications
                }
            }
        }
    }
    
    /// Update active errors from the notification system.
    /// Called by the AppNotificationSystem actor.
    func updateErrors(_ errors: [AppError]) {
        activeErrors = errors
    }
    
    func setIsConnected(_ connected: Bool) {
        isConnected = connected
    }
    
    /// UUID of the currently selected light group for HUD anchoring.
    var selectedGroupId: String?
    
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
    private func merge<T: Identifiable>(existing: [T], incoming: [T]) -> [T]
    where T.ID == String {
        var result = existing
        let incomingById = Dictionary(grouping: incoming) { $0.id }
        
        for (id, newItems) in incomingById {
            guard let newItem = newItems.last else { continue }
            if let idx = result.firstIndex(where: { $0.id == id }) {
                result[idx] = newItem
            } else {
                result.append(newItem)
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
    /// Persists the mapping atomically via SwiftData.
    func linkFixture(_ fixtureId: UUID, toLight lightId: String) {
        fixtureLightMapping[fixtureId] = lightId
        Task {
            await persistence.linkFixture(fixtureId, toLight: lightId)
        }
    }
    
    /// Unlink a local fixture from its mapped Hue light.
    /// Persists the change atomically via SwiftData.
    func unlinkFixture(_ fixtureId: UUID) {
        fixtureLightMapping.removeValue(forKey: fixtureId)
        Task {
            await persistence.unlinkFixture(fixtureId)
        }
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
    
    /// Report an error to the notification system for UI display.
    /// Uses the AppNotificationSystem actor to prevent main-thread hangs
    /// during SSE reconnection bursts by deduplicating and rate-limiting.
    func reportError(_ error: any Error, severity: AppErrorSeverity = .error, source: String) {
        Task { [notificationSystem] in
            await notificationSystem.enqueueNotification(error, severity: severity, source: source)
        }
    }
    
    /// Dismiss a specific error from the queue.
    func dismissError(_ error: AppError) {
        Task { [notificationSystem] in
            await notificationSystem.dismissNotification(withId: error.id)
        }
    }
    
    /// Clear all active errors.
    func clearErrors() {
        Task { [notificationSystem] in
            await notificationSystem.clearAllNotifications()
        }
    }
    
    // MARK: - State Persistence
    
    /// Load persisted fixture-light mappings from SwiftData.
    private func loadPersistedState() {
        Task {
            let mappings = await persistence.loadMappings()
            self.fixtureLightMapping = Dictionary(
                uniqueKeysWithValues: mappings.compactMap { mapping in
                    guard let lightId = mapping.lightId else { return nil }
                    return (mapping.uuid, lightId)
                }
            )
        }
    }
    
    /// Save a fixture mapping with spatial coordinates to SwiftData.
    func saveFixtureMapping(
        fixtureId: UUID,
        lightId: String?,
        position: SIMD3<Float>,
        orientation: simd_quatf,
        distanceMeters: Float,
        fixtureType: String,
        confidence: Double
    ) {
        Task {
            await persistence.saveMapping(
                fixtureId: fixtureId,
                lightId: lightId,
                position: position,
                orientation: orientation,
                distanceMeters: distanceMeters,
                fixtureType: fixtureType,
                confidence: confidence
            )
        }
    }
    
    /// Mark a fixture mapping as synced to the Hue Bridge.
    func markFixtureSynced(_ fixtureId: UUID) {
        Task {
            await persistence.markSynced(fixtureId)
        }
    }
    
    /// Clear all persisted fixture mappings.
    func clearPersistedState() {
        Task {
            await persistence.clearAllMappings()
        }
        fixtureLightMapping.removeAll()
    }
}


