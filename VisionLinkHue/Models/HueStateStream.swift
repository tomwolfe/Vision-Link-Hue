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
    
    /// Active auto-dismiss tasks keyed by notification ID.
    private var autoDismissTasks: [UUID: Task<Void, Never>] = [:]
    
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
        
        // Cancel any existing auto-dismiss task for this notification ID
        autoDismissTasks[appError.id]?.cancel()
        autoDismissTasks.removeValue(forKey: appError.id)
        
        activeNotifications.append(appError)
        lastNotificationTimeBySource[source] = Date()
        
        // Notify UI of the updated notification list
        onNotification?(activeNotifications)
        
        // Auto-dismiss informational errors after 3 seconds
        if severity == .informational {
            let task = Task { [weak self] in
                do {
                    try await Task.sleep(for: .seconds(3))
                    await self?.dismissNotification(withId: appError.id)
                } catch {
                    // Task was cancelled, silently ignore
                }
            }
            autoDismissTasks[appError.id] = task
        }
    }
    
    /// Dismiss a specific notification by ID.
    func dismissNotification(withId id: UUID) {
        activeNotifications.removeAll { $0.id == id }
        autoDismissTasks.removeValue(forKey: id)?.cancel()
        onNotification?(activeNotifications)
    }
    
    /// Clear all active notifications.
    func clearAllNotifications() {
        activeNotifications.removeAll()
        for task in autoDismissTasks.values {
            task.cancel()
        }
        autoDismissTasks.removeAll()
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
///
/// Optimizes SSE event processing by deferring array sorting until UI
/// consumption, avoiding O(n log n) re-sorting on every update packet.
@Observable
@MainActor
final class HueStateStream {
    
    /// Internal storage keyed by resource ID for O(1) lookup and merge.
    private var _lights: [String: HueLightResource] = [:]
    private var _scenes: [String: HueSceneResource] = [:]
    private var _groups: [String: BridgeGroup] = [:]
    private var _matterDevices: [String: MatterLightDevice] = [:]
    
    /// Whether the lights array needs re-sorting before UI access.
    private var _lightsNeedsResort = false
    
    /// Whether the scenes array needs re-sorting before UI access.
    private var _scenesNeedsResort = false
    
    /// Whether the groups array needs re-sorting before UI access.
    private var _groupsNeedsResort = false
    
    /// Whether the Matter devices array needs re-sorting before UI access.
    private var _matterDevicesNeedsResort = false
    
    /// Cached sorted lights array to avoid redundant sorting.
    private var _lightsCache: [HueLightResource]?
    
    /// Cached sorted scenes array to avoid redundant sorting.
    private var _scenesCache: [HueSceneResource]?
    
    /// Cached sorted groups array to avoid redundant sorting.
    private var _groupsCache: [BridgeGroup]?
    
    /// Cached sorted Matter devices array to avoid redundant sorting.
    private var _matterDevicesCache: [MatterLightDevice]?
    
    /// Computed array of lights for SwiftUI observation and UI consumption.
    /// Uses lazy sorting with caching to avoid O(n log n) on every SSE packet.
    var lights: [HueLightResource] {
        if _lightsNeedsResort || _lightsCache == nil {
            _lightsCache = _lights.values.sorted { $0.id < $1.id }
            _lightsNeedsResort = false
        }
        return _lightsCache!
    }
    
    /// Computed array of scenes for SwiftUI observation and UI consumption.
    /// Uses lazy sorting with caching to avoid O(n log n) on every SSE packet.
    var scenes: [HueSceneResource] {
        if _scenesNeedsResort || _scenesCache == nil {
            _scenesCache = _scenes.values.sorted { $0.id < $1.id }
            _scenesNeedsResort = false
        }
        return _scenesCache!
    }
    
    /// Computed array of groups for SwiftUI observation and UI consumption.
    /// Uses lazy sorting with caching to avoid O(n log n) on every SSE packet.
    var groups: [BridgeGroup] {
        if _groupsNeedsResort || _groupsCache == nil {
            _groupsCache = _groups.values.sorted { $0.id < $1.id }
            _groupsNeedsResort = false
        }
        return _groupsCache!
    }
    
    /// Computed array of Matter devices for SwiftUI observation and UI consumption.
    /// Uses lazy sorting with caching to avoid O(n log n) on every update.
    var matterDevices: [MatterLightDevice] {
        if _matterDevicesNeedsResort || _matterDevicesCache == nil {
            _matterDevicesCache = _matterDevices.values.sorted { $0.id < $1.id }
            _matterDevicesNeedsResort = false
        }
        return _matterDevicesCache!
    }
    
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
        
        Task { [persistence] in
            if await persistence.isUsingInMemoryStorage {
                let inMemoryError = NSError(
                    domain: "FixturePersistence",
                    code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey: "Fixture mappings are stored in memory only and will be lost when the app closes. Persistent storage is unavailable."
                    ]
                )
                reportError(inMemoryError, severity: .critical, source: "FixturePersistence")
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
    /// Merges incoming resources into the dictionary store in O(1) per item,
    /// deferring sorting until UI access to avoid O(n log n) on every packet.
    func applyUpdate(_ update: ResourceUpdate) {
        if let lights = update.lights {
            mergeIntoDictionary(&self._lights, incoming: lights)
            _lightsNeedsResort = true
            _lightsCache = nil
        }
        
        if let scenes = update.scenes {
            mergeIntoDictionary(&self._scenes, incoming: scenes)
            _scenesNeedsResort = true
            _scenesCache = nil
        }
        
        if let groups = update.groups {
            mergeIntoDictionary(&self._groups, incoming: groups)
            _groupsNeedsResort = true
            _groupsCache = nil
        }
        
        if let matterLights = update.matterLights {
            for device in matterLights {
                _matterDevices[device.id] = device
            }
            _matterDevicesNeedsResort = true
            _matterDevicesCache = nil
        }
    }
    
    /// Merge incoming identifiable resources into a dictionary-backed store,
    /// replacing entries with matching IDs in O(1). Does not sort - sorting
    /// is deferred until UI access via the `needsResort` flag.
    private func mergeIntoDictionary<T: Identifiable>(
        _ store: inout [String: T],
        incoming: [T]
    ) where T.ID == String {
        for item in incoming {
            store[item.id] = item
        }
    }
    
    /// Resolve a light by its bridge-assigned ID.
    func light(by id: String) -> HueLightResource? {
        _lights[id]
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
        _scenes[id]
    }
    
    /// Get all lights belonging to a group.
    func lights(inGroup groupId: String) -> [HueLightResource] {
        guard let group = _groups[groupId] else { return [] }
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
    
    /// Force re-sort all resource arrays.
    /// Called when the UI explicitly requests a refresh.
    func refreshSortedArrays() {
        _lightsNeedsResort = true
        _scenesNeedsResort = true
        _groupsNeedsResort = true
        _matterDevicesNeedsResort = true
        _lightsCache = nil
        _scenesCache = nil
        _groupsCache = nil
        _matterDevicesCache = nil
    }
    
    /// Update Matter device state from the MatterBridgeService.
    func updateMatterDevices(_ devices: [MatterLightDevice]) {
        for device in devices {
            _matterDevices[device.id] = device
        }
        _matterDevicesNeedsResort = true
        _matterDevicesCache = nil
    }
    
    /// Resolve a Matter device by its ID.
    func matterDevice(by id: String) -> MatterLightDevice? {
        _matterDevices[id]
    }
    
    /// Check if Matter fallback has reachable devices.
    var hasReachableMatterDevices: Bool {
        _matterDevices.values.contains { $0.isReachable }
    }
    
    /// Report a certificate pin mismatch to the user.
    /// This occurs when the bridge has been factory-reset and presents a new TLS certificate.
    func reportCertificatePinMismatch(newHash: Data, oldHash: Data) {
        let mismatchError = NSError(
            domain: "CertificatePinning",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey: "Certificate pin mismatch detected. The bridge may have been factory-reset. Tap settings to re-verify the connection."
            ]
        )
        reportError(mismatchError, severity: .critical, source: "CertificatePinning.mismatch")
    }
}


