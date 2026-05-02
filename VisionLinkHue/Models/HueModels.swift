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
    let metadata: SceneMetadata
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
