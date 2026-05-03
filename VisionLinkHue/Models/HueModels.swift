import Foundation

// MARK: - CLIP v2 Resource Models

/// A single Hue light resource.
struct HueLightResource: Codable, Sendable {
    let id: String
    let type: String
    let metadata: Metadata
    let state: LightState
    let product: ProductInfo?
    let config: Config
    
    struct Metadata: Codable, Sendable {
        var name: String?
        private var archetype: String?
        var archetypeValue: Archetype {
            Archetype(rawValue: archetype ?? "")
        }
        var manufacturerCode: String?
        var firmwareVersion: String?
        var hardwarePlatformType: String?
        
        enum Archetype: String, Codable, Sendable {
            case unknown = "unknown"
            case hueBulb = "hue_bulb"
            case hueLightStrip = "hue_lightstrip"
            case hueIbulb = "hue_i bulb"
            case tableSpotlight = "table_spotlight"
            case ceilingBulb = "ceiling_bulb"
            case hueGo = "hue_go"
            case lightStripPlus = "lightstrip_plus"
            case pendantLight = "pendant_light"
            case ceilingCornerLight = "ceiling_corner_light"
            case ceilingRoundLight = "ceiling_round_light"
            case ceilingSquareLight = "ceiling_square_light"
            case spot = "spot"
            case downlight = "downlight"
            case br30 = "br30"
            case colorSpot = "color_spot"
            case ambiance = "ambiance"
            case candle = "candle"
            case nightlight = "nightlight"
            case unknownCase = "unknown"
        }
    }
    
    struct LightState: Codable, Sendable {
        var on: Bool?
        var brightness: Int?
        var xy: [Double]?
        var hue: Int?
        var saturation: Int?
        var ct: Int?
        var colormode: String?
        
        /// Convenience: current color temperature in mireds.
        var colorTemperatureMireds: Int? { ct }
        
        /// Convenience: current XY color coordinates.
        var colorXY: (x: Double, y: Double)? {
            guard let xy = xy, xy.count >= 2 else { return nil }
            return (xy[0], xy[1])
        }
        
        /// Convenience: current hue in range [0, 65535].
        var hueValue: Int? { hue }
        
        /// Convenience: current saturation in range [0, 255].
        var saturationValue: Int? { saturation }
    }
    
    struct Product: Codable, Sendable {
        var name: String?
        var manufacturerName: String?
        var modelID: String?
        var productID: String?
    }
    
    struct Config: Codable, Sendable {
        var reachable: Bool?
    }
    
    enum CodingKeys: String, CodingKey {
        case id, type, metadata, state, product, config
    }
}

/// A Hue scene resource.
struct HueSceneResource: Codable, Sendable {
    let id: String
    let type: String
    let metadata: Metadata
    let data: SceneData?
    let lights: [String]?
    
    struct Metadata: Codable, Sendable {
        var name: String?
        var archetype: String?
    }
    
    struct SceneData: Codable, Sendable {
        var group: String?
        var lightlevel: Int?
    }
    
    enum CodingKeys: String, CodingKey {
        case id, type, metadata, data, lights
    }
}

// MARK: - Bridge State

/// The complete bridge state as delivered via SSE.
struct HueBridgeState: Codable, Sendable {
    let lights: [HueLightResource]?
    let scenes: [HueSceneResource]?
    let groups: [BridgeGroup]?
    let resources: ResourceUpdate?
    
    /// Convenience accessor for bridge spatial capabilities.
    var spatialInfo: BridgeSpatialInfo {
        BridgeSpatialInfo.from(bridgeState: self)
    }
}

/// Partial resource update from SSE fragment.
struct ResourceUpdate: Codable, Sendable {
    let lights: [HueLightResource]?
    let scenes: [HueSceneResource]?
    let groups: [BridgeGroup]?
}

/// A Hue group (room, area, or light list).
struct BridgeGroup: Codable, Sendable {
    let id: String
    let type: String
    let state: GroupState
    let action: GroupState
    let lights: [String]
    let name: String
    
    struct GroupState: Codable, Sendable {
        var any_on: Bool?
        var all_on: Bool?
    }
}

// MARK: - API Request/Response Types

/// PUT request body for setting light state (CLIP v2).
struct LightStatePatch: Codable, Sendable {
    var on: Bool?
    var brightness: Int?
    var hue: Int?
    var saturation: Int?
    var ct: Int?
    var xy: [Double]?
    var transitionduration: Int?
    
    init(
        on: Bool? = nil,
        brightness: Int? = nil,
        hue: Int? = nil,
        saturation: Int? = nil,
        ct: Int? = nil,
        xy: (Double, Double)? = nil,
        transitionDuration: Int? = nil
    ) {
        self.on = on
        self.brightness = brightness
        self.hue = hue
        self.saturation = saturation
        self.ct = ct
        self.xy = xy.map { [$0.0, $0.1] }
        self.transitionduration = transitionDuration ?? 4
    }
}

/// PUT request body for recalling a scene.
struct ScenePatch: Codable, Sendable {
    var on: Bool
    var scene: String
}

/// POST request to create a developer session (API key).
struct CreateApiKeyRequest: Codable, Sendable {
    let devicetype: String
}

/// Response from API key creation.
struct CreateApiKeyResponse: Codable, Sendable {
    let success: SuccessResponse?
    
    struct SuccessResponse: Codable, Sendable {
        let username: String
    }
}

/// Bridge configuration.
struct BridgeConfig: Codable, Sendable {
    let mac: String?
    let ipaddress: String?
    let port: Int?
    let username: String?
}

// MARK: - SpatialAware API (Spring 2026)

/// Firmware version threshold required for SpatialAware features.
/// Bridge Pro firmware v1976+ or v2 Bridge with 2026 Spring update.
enum SpatialAwareFirmwareRequirement {
    static let minimumMajor = 1
    static let minimumMinor = 976
}

/// Spatial awareness data for a detected fixture, used to sync
/// AR-detected positions back to the Hue Bridge for accurate
/// preset scene rendering.
struct SpatialAwarePosition: Codable, Sendable {
    /// The CLIP v2 light resource ID.
    let id: String
    
    /// 3D position in meters relative to the bridge's coordinate system.
    let position: Position3D
    
    /// Detection confidence from the Vision framework (0.0-1.0).
    let confidence: Double
    
    /// Fixture type detected by the on-device classifier.
    let fixtureType: String
    
    /// Optional room/area assignment from the bridge.
    let roomId: String?
    
    /// Optional area/zone assignment from the bridge.
    let areaId: String?
    
    /// Spatial calibration timestamp.
    let timestamp: Date
    
    /// Orientation quaternion for accurate light beam direction.
    let orientation: Orientation?
    
    /// Material label from ARKit Neural Surface Synthesis (e.g., "Glass", "Metal", "Wood").
    let materialLabel: String?
    
    /// Room-relative offset within the assigned room.
    let roomOffset: RoomOffset?
    
    struct Position3D: Codable, Sendable {
        let x: Double
        let y: Double
        let z: Double
        
        init(x: Double, y: Double, z: Double) {
            self.x = x
            self.y = y
            self.z = z
        }
        
        init(simd: SIMD3<Float>) {
            self.x = Double(simd.x)
            self.y = Double(simd.y)
            self.z = Double(simd.z)
        }
    }
    
    struct Orientation: Codable, Sendable {
        let x: Double
        let y: Double
        let z: Double
        let w: Double
        
        init(simd: simd_quatf) {
            self.x = Double(simd.x)
            self.y = Double(simd.y)
            self.z = Double(simd.z)
            self.w = Double(simd.w)
        }
        
        init(x: Double, y: Double, z: Double, w: Double) {
            self.x = x
            self.y = y
            self.z = z
            self.w = w
        }
    }
    
    /// Room-relative offset for precise fixture placement within a room.
    struct RoomOffset: Codable, Sendable {
        /// Offset X from room origin in meters.
        let relativeX: Double
        /// Offset Y from room origin in meters.
        let relativeY: Double
        /// Offset Z from room origin in meters.
        let relativeZ: Double
        
        init(relativeX: Double, relativeY: Double, relativeZ: Double) {
            self.relativeX = relativeX
            self.relativeY = relativeY
            self.relativeZ = relativeZ
        }
        
        init(simd: SIMD3<Float>) {
            self.relativeX = Double(simd.x)
            self.relativeY = Double(simd.y)
            self.relativeZ = Double(simd.z)
        }
    }
}

/// Request body for syncing spatial awareness data to the bridge.
struct SpatialAwareSyncRequest: Codable, Sendable {
    let fixtures: [SpatialAwarePosition]
    let coordinateSystem: CoordinateSystem
    let calibrationTimestamp: Date
    
    enum CoordinateSystem: String, Codable, Sendable {
        case bridgeRoomSpace = "bridge_room_space"
        case localRoomSpace = "local_room_space"
    }
    
    init(fixtures: [SpatialAwarePosition]) {
        self.fixtures = fixtures
        self.coordinateSystem = .bridgeRoomSpace
        self.calibrationTimestamp = Date()
    }
}

/// Response from the SpatialAware sync endpoint.
struct SpatialAwareSyncResponse: Codable, Sendable {
    let success: [SpatialAwareSuccess]
    let warnings: [SpatialAwareWarning]?
    let errors: [SpatialAwareError]?
    
    struct SpatialAwareSuccess: Codable, Sendable {
        let id: String
        let status: String
        let roomId: String?
        let confidence: Double?
    }
    
    struct SpatialAwareWarning: Codable, Sendable {
        let id: String
        let message: String
        let code: String?
    }
    
    struct SpatialAwareError: Codable, Sendable {
        let id: String
        let message: String
        let code: String
    }
}

/// Partial spatial awareness update from SSE events.
struct SpatialAwareUpdate: Codable, Sendable {
    let spatial_awareness: [SpatialAwareResource]?
    
    struct SpatialAwareResource: Codable, Sendable {
        let id: String
        let position: SpatialAwarePosition.Position3D?
        let confidence: Double?
        let last_seen: Date?
        let roomId: String?
        let areaId: String?
    }
}

/// Bridge firmware and spatial capabilities info.
struct BridgeSpatialInfo: Sendable {
    let firmwareVersion: String
    let supportsSpatialAware: Bool
    let supportsRoomMapping: Bool
    let supportedMaterialLabels: [String]
    
    static func from(bridgeState: HueBridgeState) -> BridgeSpatialInfo {
        let fw = bridgeState.resources?.spatial_awareness?.firmware_version ?? "0.0"
        let parts = fw.split(separator: ".").compactMap { Int($0) }
        let major = parts.first ?? 0
        let minor = parts.count > 1 ? parts[1] : 0
        
        let supportsSpatial = major > SpatialAwareFirmwareRequirement.minimumMajor ||
            (major == SpatialAwareFirmwareRequirement.minimumMajor && minor >= SpatialAwareFirmwareRequirement.minimumMinor)
        
        return BridgeSpatialInfo(
            firmwareVersion: fw,
            supportsSpatialAware: supportsSpatial,
            supportsRoomMapping: supportsSpatial,
            supportedMaterialLabels: ["Glass", "Metal", "Wood", "Fabric", "Plaster", "Concrete"]
        )
    }
}

