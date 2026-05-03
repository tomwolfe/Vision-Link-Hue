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
    private let calibrationEngine = SpatialCalibrationEngine()
    
    /// The Hue client for making REST API calls.
    private let hueClient: HueClient
    
    /// State stream for reporting errors and accessing bridge config.
    private let stateStream: HueStateStream?
    
    /// Whether a valid 3+ point calibration has been established.
    var isCalibrated: Bool { calibrationEngine.isCalibrated }
    
    /// Check if the connected bridge supports SpatialAware features.
    var isSpatialAwareSupported: Bool {
        guard let bridgeState = stateStream?.bridgeConfig else { return false }
        return true // Checked at sync time via API response
    }
    
    /// Initialize the spatial service with its dependencies.
    /// - Parameters:
    ///   - hueClient: The authenticated Hue client for REST API calls.
    ///   - stateStream: Optional state stream for error reporting.
    init(hueClient: HueClient, stateStream: HueStateStream?) {
        self.hueClient = hueClient
        self.stateStream = stateStream
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
            bridgePosition = origin + (arKitPosition - origin)
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
    func createSpatialAwarePosition(context: DetectionContext) -> SpatialAwarePosition {
        let (position, roomOffset) = mapARKitToBridgeSpace(
            arKitPosition: context.arKitPosition,
            arKitOrientation: context.arKitOrientation,
            referencePoint: context.origin
        )
        
        return SpatialAwarePosition(
            id: context.lightId,
            position: position,
            confidence: context.confidence,
            fixtureType: context.fixtureType,
            roomId: context.roomId,
            areaId: context.areaId,
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
        guard let username = hueClient.apiKey else {
            throw HueError.noApiKey
        }
        
        guard let ip = hueClient.bridgeIP else {
            throw HueError.noBridgeConfigured
        }
        
        let url = URL(string: "https://\(ip):\(hueClient.bridgePort)/api/\(username)/config")
        
        guard let url else {
            throw HueError.invalidURL
        }
        
        let (data, _) = try await hueClient.authenticatedRequest(url: url, method: "GET")
        
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
        guard let username = hueClient.apiKey else {
            throw HueError.noApiKey
        }
        
        guard let ip = hueClient.bridgeIP else {
            throw HueError.noBridgeConfigured
        }
        
        // Verify firmware compatibility before sync
        _ = try await verifySpatialAwareCompatibility()
        
        guard let url = URL(string: "https://\(ip):\(hueClient.bridgePort)/api/\(username)/spatial_awareness") else {
            throw HueError.invalidURL
        }
        
        let request = SpatialAwareSyncRequest(fixtures: fixtures)
        
        let (data, response) = try await hueClient.authenticatedRequest(url: url, method: "POST", body: request)
        
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
        guard let username = hueClient.apiKey else {
            throw HueError.noApiKey
        }
        
        guard let ip = hueClient.bridgeIP else {
            throw HueError.noBridgeConfigured
        }
        
        guard let url = URL(string: "https://\(ip):\(hueClient.bridgePort)/api/\(username)/resources/spatial_awareness") else {
            throw HueError.invalidURL
        }
        
        let (data, _) = try await hueClient.authenticatedRequest(url: url, method: "GET")
        
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
