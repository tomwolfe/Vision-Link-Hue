import Foundation
import simd
import os

/// Service responsible for spatial awareness with the Philips Hue Bridge.
/// Handles coordinate calibration (Kabsch algorithm), spatial awareness
/// position creation, and syncing fixture positions to the bridge.
@MainActor
final class HueSpatialService {
    
    private let logger = Logger(
        subsystem: "com.tomwolfe.visionlinkhue",
        category: "HueSpatial"
    )
    
    /// Dedicated engine for computing ARKit-to-Bridge coordinate transformations
    /// using the Kabsch algorithm with SVD for numerical stability.
    let calibrationEngine = SpatialCalibrationEngine()
    
    /// The Hue client for making REST API calls.
    private weak var hueClient: HueClient?
    
    /// State stream for reporting errors and accessing bridge config.
    private let stateStream: HueStateStream?
    
    /// Whether a valid 3+ point calibration has been established.
    var isCalibrated: Bool { calibrationEngine.isCalibrated }
    
    /// Check if the connected bridge supports SpatialAware features.
    var isSpatialAwareSupported: Bool {
        guard let bridgeState = stateStream?.bridgeConfig else { return false }
        return true // Checked at sync time via API response
    }
    
    // MARK: - Manual Placement Mode
    
    /// Whether Manual Placement mode is active (for older Bridge hardware).
    var isManualPlacementActive: Bool {
        _manualPlacementMode != .inactive
    }
    
    /// The current manual placement mode state.
    enum ManualPlacementMode: Sendable {
        /// Spatial features are available and functioning normally.
        case inactive
        /// User is manually assigning room/zone to a fixture.
        case placing(fixtureId: UUID, lightId: String?)
        /// User has completed manual placement for a fixture.
        case placed(fixtureId: UUID, roomId: String, areaId: String?)
    }
    
    private var _manualPlacementMode: ManualPlacementMode = .inactive
    
    /// The user-defined room mapping for manual placement mode.
    /// Maps fixture UUIDs to their manually assigned room and area.
    private var manualRoomAssignments: [UUID: (roomId: String, areaId: String?)] = [:]
    
    /// Get the manual room assignment for a fixture.
    func manualRoomAssignment(for fixtureId: UUID) -> (roomId: String, areaId: String?)? {
        manualRoomAssignments[fixtureId]
    }
    
    /// Set the manual room assignment for a fixture.
    func setManualRoomAssignment(fixtureId: UUID, roomId: String, areaId: String?) {
        manualRoomAssignments[fixtureId] = (roomId: roomId, areaId: areaId)
        _manualPlacementMode = .placed(fixtureId: fixtureId, roomId: roomId, areaId: areaId)
        logger.info("Manual placement set for fixture \(fixtureId): room=\(roomId), area=\(areaId ?? "none")")
    }
    
    /// Enter manual placement mode for a specific fixture.
    func enterManualPlacementMode(fixtureId: UUID, lightId: String?) {
        _manualPlacementMode = .placing(fixtureId: fixtureId, lightId: lightId)
        logger.info("Entered manual placement mode for fixture \(fixtureId)")
    }
    
    /// Exit manual placement mode and return to normal operation.
    func exitManualPlacementMode() {
        _manualPlacementMode = .inactive
        logger.info("Exited manual placement mode")
    }
    
    /// Get all manual room assignments for persistence.
    func getAllManualAssignments() -> [UUID: (roomId: String, areaId: String?)] {
        manualRoomAssignments
    }
    
    /// Restore manual room assignments from persistence.
    func restoreManualAssignments(_ assignments: [UUID: (roomId: String, areaId: String?)]) {
        manualRoomAssignments = assignments
        logger.info("Restored \(assignments.count) manual room assignments")
    }
    
    /// Initialize the spatial service with its dependencies.
    /// - Parameters:
    ///   - hueClient: The authenticated Hue client for REST API calls.
    ///   - stateStream: Optional state stream for error reporting.
    init(stateStream: HueStateStream?) {
        self.stateStream = stateStream
        Task {
            let loaded = await calibrationEngine.loadPersistedCalibration()
            if loaded {
                logger.info("Calibration restored from persistence")
            }
        }
    }
    
    func setHueClient(_ client: HueClient) {
        self.hueClient = client
    }
    
    // MARK: - Calibration
    
    /// Add a calibration point to the affine transformation solver.
    /// Requires at least 3 points for a valid calibration.
    /// Points are stored in FIFO order with a maximum of 6 points.
    func addCalibrationPoint(arKit: SIMD3<Float>, bridge: SIMD3<Float>) {
        calibrationEngine.addCalibrationPoint(arKit: arKit, bridge: bridge)
    }
    
    /// Clear all calibration points.
    func clearCalibration() {
        calibrationEngine.clearCalibration()
    }
    
    /// Get the current calibration points for inspection.
    func getCalibrationPoints() -> [(arKit: SIMD3<Float>, bridge: SIMD3<Float>)] {
        calibrationEngine.getCalibrationPoints()
    }
    
    // MARK: - Coordinate Transformation
    
    /// Map ARKit local space coordinates to Bridge Room Space coordinates.
    /// Uses the Kabsch algorithm when calibrated, falling back
    /// to a single-point origin offset when calibration is unavailable.
    /// The bridge requires room_offset to be calibrated against the room's
    /// primary entrance or a "Bridge Origin" defined in the Hue App.
    func mapARKitToBridgeSpace(
        arKitPosition: SIMD3<Float>,
        arKitOrientation: simd_quatf,
        referencePoint: SIMD3<Float>? = nil
    ) -> (position: SpatialAwarePosition.Position3D, roomOffset: SpatialAwarePosition.RoomOffset?) {
        let bridgePosition: SIMD3<Float>
        
        if isCalibrated {
            // Apply Kabsch transformation for large-room accuracy
            bridgePosition = calibrationEngine.mapToBridgeSpace(arKitPosition)
        } else if let origin = referencePoint {
            // Fallback: single-point origin offset
            bridgePosition = arKitPosition - origin
        } else {
            // Default: identity mapping
            bridgePosition = arKitPosition
        }
        
        let position = SpatialAwarePosition.Position3D(simd: bridgePosition)
        let roomOffset = SpatialAwarePosition.RoomOffset(
            relativeX: Double(bridgePosition.x),
            relativeY: Double(bridgePosition.y),
            relativeZ: Double(bridgePosition.z)
        )
        
        return (position, roomOffset)
    }
    
    // MARK: - SpatialAware Position Creation
    
    /// Create a full SpatialAwarePosition from ARKit detection data with
    /// room-relative coordinate mapping.
    /// When in manual placement mode, uses user-assigned room/area instead
    /// of bridge-derived values for older hardware compatibility.
    func createSpatialAwarePosition(context: DetectionContext) -> SpatialAwarePosition {
        let (position, roomOffset) = mapARKitToBridgeSpace(
            arKitPosition: context.arKitPosition,
            arKitOrientation: context.arKitOrientation,
            referencePoint: context.origin
        )
        
        // In manual placement mode, use user-assigned room/area
        let roomId: String?
        let areaId: String?
        if isManualPlacementActive {
            let manual = manualRoomAssignments[context.lightId.map { UUID(uuidString: $0) } ?? UUID()]
            roomId = manual?.roomId
            areaId = manual?.areaId
        } else {
            roomId = context.roomId
            areaId = context.areaId
        }
        
        return SpatialAwarePosition(
            id: context.lightId,
            position: position,
            confidence: context.confidence,
            fixtureType: context.fixtureType,
            roomId: roomId,
            areaId: areaId,
            timestamp: Date(),
            orientation: SpatialAwarePosition.Orientation(simd: context.arKitOrientation),
            materialLabel: context.materialLabel,
            roomOffset: roomOffset
        )
    }
    
    // MARK: - Firmware Verification
    
    /// Verify firmware compatibility before attempting SpatialAware sync.
    /// Returns the bridge spatial info if supported, throws otherwise.
    func verifySpatialAwareCompatibility() async throws -> BridgeSpatialInfo {
        guard let username = hueClient?.apiKey else {
            throw HueError.noApiKey
        }
        
        guard let ip = hueClient?.bridgeIP else {
            throw HueError.noBridgeConfigured
        }
        
        let url = URL(string: "https://\(ip):\(hueClient?.bridgePort ?? 443)/api/\(username)/config")
        
        guard let url else {
            throw HueError.invalidURL
        }
        
        let (data, _) = try await hueClient!.authenticatedRequest(url: url, method: "GET")
        
        // Decode bridge config to extract firmware version using type-safe Codable
        let bridgeConfig = try JSONDecoder().decode(BridgeConfigResponse.self, from: data)
        
        guard let firmwareString = bridgeConfig.softwareVersion?.main else {
            // Fallback: assume supported if we can reach the endpoint
            return BridgeSpatialInfo(
                firmwareVersion: "unknown",
                supportsSpatialAware: true,
                supportsRoomMapping: false,
                supportedMaterialLabels: []
            )
        }
        
        let parts = firmwareString.split(separator: ".").compactMap { Int($0) }
        let major = parts.first ?? 0
        let minor = parts.count > 1 ? parts[1] : 0
        
        let supportsSpatial = major > SpatialAwareFirmwareRequirement.minimumMajor ||
            (major == SpatialAwareFirmwareRequirement.minimumMajor && minor >= SpatialAwareFirmwareRequirement.minimumMinor)
        
        guard supportsSpatial else {
            throw HueError.spatialAwareNotSupported(
                currentFirmware: firmwareString,
                requiredFirmware: "\(SpatialAwareFirmwareRequirement.minimumMajor).\(SpatialAwareFirmwareRequirement.minimumMinor)"
            )
        }
        
        return BridgeSpatialInfo(
            firmwareVersion: firmwareString,
            supportsSpatialAware: true,
            supportsRoomMapping: true,
            supportedMaterialLabels: ["Glass", "Metal", "Wood", "Fabric", "Plaster", "Concrete"]
        )
    }
    
    // MARK: - Spatial Awareness Sync
    
    /// Sync AR-detected fixture positions back to the Hue Bridge.
    /// Bridges Pro firmware v1976+ supports room-relative coordinate offsets.
    /// Automatically verifies firmware compatibility before syncing.
    func syncSpatialAwareness(fixtures: [SpatialAwarePosition]) async throws {
        guard let username = hueClient?.apiKey else {
            throw HueError.noApiKey
        }
        
        guard let ip = hueClient?.bridgeIP else {
            throw HueError.noBridgeConfigured
        }
        
        // Verify firmware compatibility before sync
        _ = try await verifySpatialAwareCompatibility()
        
        guard let url = URL(string: "https://\(ip):\(hueClient?.bridgePort ?? 443)/api/\(username)/spatial_awareness") else {
            throw HueError.invalidURL
        }
        
        let request = SpatialAwareSyncRequest(fixtures: fixtures)
        
        let (data, response) = try await hueClient?.authenticatedRequest(url: url, method: "POST", body: request) ?? (Data(), nil)
        
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw HueError.invalidResponse
        }
        
        let syncResponse = try JSONDecoder().decode(SpatialAwareSyncResponse.self, from: data)
        
        if let errors = syncResponse.errors, !errors.isEmpty {
            let errorMessages = errors.map { "[$( $0.code)] \($0.message)" }.joined(separator: ", ")
            logger.error("SpatialAware sync errors: \(errorMessages)")
            throw HueError.spatialAwareSyncFailed(errors: errors.map { SpatialAwareSyncError(code: $0.code, message: $0.message) })
        }
        
        if let warnings = syncResponse.warnings, !warnings.isEmpty {
            let warningMessages = warnings.map { $0.message }.joined(separator: ", ")
            logger.warning("SpatialAware sync warnings: \(warningMessages)")
        }
        
        logger.info("Synced \(syncResponse.success.count) fixture positions to bridge")
    }
    
    /// Sync a single fixture's spatial awareness data.
    func syncSpatialAwareness(fixture: SpatialAwarePosition) async throws {
        try await syncSpatialAwareness(fixtures: [fixture])
    }
    
    /// Get current spatial awareness data from the bridge.
    func fetchSpatialAwareness() async throws -> [SpatialAwarePosition] {
        guard let username = hueClient?.apiKey else {
            throw HueError.noApiKey
        }
        
        guard let ip = hueClient?.bridgeIP else {
            throw HueError.noBridgeConfigured
        }
        
        guard let url = URL(string: "https://\(ip):\(hueClient?.bridgePort ?? 443)/api/\(username)/resources/spatial_awareness") else {
            throw HueError.invalidURL
        }
        
        let (data, _) = try await hueClient?.authenticatedRequest(url: url, method: "GET") ?? (Data(), nil)
        
        let response = try JSONDecoder().decode(SpatialAwareSyncResponse.self, from: data)
        
        return response.success.compactMap { success in
            // Reconstruct positions from bridge response
            guard let light = stateStream?.light(by: success.id) else { return nil }
            
            return SpatialAwarePosition(
                id: success.id,
                position: SpatialAwarePosition.Position3D(x: 0, y: 0, z: 0),
                confidence: success.confidence ?? 0.0,
                fixtureType: light.metadata.archetypeValue.rawValue,
                roomId: success.roomId,
                areaId: nil,
                timestamp: Date(),
                orientation: nil,
                materialLabel: nil,
                roomOffset: nil
            )
        }
    }
}
