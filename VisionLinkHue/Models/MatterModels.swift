import Foundation
import HomeKit
import os

// MARK: - Matter Device Models

/// Unified Matter device type enumeration covering all Matter light clusters.
enum MatterDeviceType: String, Sendable, CaseIterable, Codable {
    case onOffLight = "on_off_light"
    case dimmableLight = "dimmable_light"
    case colorTemperatureLight = "color_temperature_light"
    case extendedColorLight = "extended_color_light"
    case unknown = "unknown"
    
    var displayName: String {
        switch self {
        case .onOffLight: return "On/Off Light"
        case .dimmableLight: return "Dimmable Light"
        case .colorTemperatureLight: return "Color Temperature Light"
        case .extendedColorLight: return "Extended Color Light"
        case .unknown: return "Unknown Device"
        }
    }
}

/// Represents a Matter-compatible smart light accessory.
struct MatterLightDevice: Identifiable, Sendable, Codable {
    let id: String
    let name: String
    let deviceType: MatterDeviceType
    let manufacturerName: String
    let modelIdentifier: String
    let firmwareVersion: String
    let isReachable: Bool
    let powerState: Bool
    let brightness: Int
    let colorTemperatureMireds: Int?
    let colorX: Double?
    let colorY: Double?
    let threadNetworkName: String?
    let commissioningMode: Int
    
    /// Convert from a HomeKit accessory to a MatterLightDevice.
    static func from(accessory: HMAccessory) -> MatterLightDevice {
        return MatterLightDevice(
            id: UUID().uuidString,
            name: accessory.name ?? "Unknown Device",
            deviceType: .unknown,
            manufacturerName: accessory.manufacturer ?? "Unknown",
            modelIdentifier: accessory.model ?? "Unknown",
            firmwareVersion: "",
            isReachable: false,
            powerState: false,
            brightness: 0,
            colorTemperatureMireds: nil,
            colorX: nil,
            colorY: nil,
            threadNetworkName: nil,
            commissioningMode: 0
        )
    }
}

// MARK: - Matter Bridge/Controller Models

/// Represents a Matter Thread border router or controller that can serve as a fallback lighting gateway.
/// Includes area metadata imported from the Thread network (Matter 1.5.1+).
struct MatterBorderRouter: Identifiable, Sendable {
    let id: String
    let name: String
    let manufacturer: String
    let model: String
    let isOnline: Bool
    let threadNetworkName: String?
    let rssi: Int?
    
    /// Area metadata from the Thread Border Router (Matter 1.5.1+).
    /// Contains room/area definitions that can pre-populate light groups
    /// when the Hue Bridge is offline.
    let areaMetadata: MatterAreaMetadata?
    
    init(
        id: String,
        name: String,
        manufacturer: String,
        model: String,
        isOnline: Bool,
        threadNetworkName: String? = nil,
        rssi: Int? = nil,
        areaMetadata: MatterAreaMetadata? = nil
    ) {
        self.id = id
        self.name = name
        self.manufacturer = manufacturer
        self.model = model
        self.isOnline = isOnline
        self.threadNetworkName = threadNetworkName
        self.rssi = rssi
        self.areaMetadata = areaMetadata
    }
}

/// Area metadata imported from a Matter Thread Border Router (Matter 1.5.1+).
/// Provides room and area definitions for pre-populating light groups offline.
struct MatterAreaMetadata: Sendable, Codable {
    /// The area ID assigned by the Thread Border Router.
    let areaId: String
    
    /// The area name (e.g., "Living Room", "Kitchen").
    let areaName: String
    
    /// Child areas within this area (hierarchical room structure).
    let childAreaIds: [String]
    
    /// Lights assigned to this area by the Matter network.
    let assignedLightIds: [String]
    
    init(
        areaId: String,
        areaName: String,
        childAreaIds: [String] = [],
        assignedLightIds: [String] = []
    ) {
        self.areaId = areaId
        self.areaName = areaName
        self.childAreaIds = childAreaIds
        self.assignedLightIds = assignedLightIds
    }
}

// MARK: - Matter State

/// Unified state representation for Matter devices, parallel to HueBridgeState.
struct MatterBridgeState: Sendable {
    let lights: [MatterLightDevice]
    let borderRouters: [MatterBorderRouter]
    let threadNetworkAvailable: Bool
    let lastUpdated: Date
    
    init(
        lights: [MatterLightDevice] = [],
        borderRouters: [MatterBorderRouter] = [],
        threadNetworkAvailable: Bool = false,
        lastUpdated: Date = Date()
    ) {
        self.lights = lights
        self.borderRouters = borderRouters
        self.threadNetworkAvailable = threadNetworkAvailable
        self.lastUpdated = lastUpdated
    }
}

// MARK: - Matter Light State Patch

/// Represents a state patch for a Matter light, analogous to LightStatePatch for Hue.
struct MatterLightStatePatch: Sendable {
    let power: Bool?
    let brightness: Int?
    let colorTemperatureMireds: Int?
    let colorX: Double?
    let colorY: Double?
    let transitionDuration: Int?
    
    init(
        power: Bool? = nil,
        brightness: Int? = nil,
        colorTemperatureMireds: Int? = nil,
        colorX: Double? = nil,
        colorY: Double? = nil,
        transitionDuration: Int? = nil
    ) {
        self.power = power
        self.brightness = brightness
        self.colorTemperatureMireds = colorTemperatureMireds
        self.colorX = colorX
        self.colorY = colorY
        self.transitionDuration = transitionDuration
    }
}

// MARK: - Matter Event Types

/// Event types from the Matter device event stream.
enum MatterEventType: String, Sendable {
    case powerStateChange = "power_state_change"
    case brightnessChange = "brightness_change"
    case colorTemperatureChange = "color_temperature_change"
    case colorXYChange = "color_xy_change"
    case reachabilityChange = "reachability_change"
    case deviceAdded = "device_added"
    case deviceRemoved = "device_removed"
    case threadNetworkChange = "thread_network_change"
}

/// Represents a single event from the Matter device stream.
struct MatterEvent: @unchecked Sendable {
    let type: MatterEventType
    let deviceId: String
    let timestamp: Date
    let changes: [String: AnyHashable]
    
    init(
        type: MatterEventType,
        deviceId: String,
        timestamp: Date = Date(),
        changes: [String: Any] = [:]
    ) {
        self.type = type
        self.deviceId = deviceId
        self.timestamp = timestamp
        self.changes = [:]
    }
}

// MARK: - Resource Update Helper

/// Helper to create a ResourceUpdate with Matter device updates.
extension ResourceUpdate {
    /// Create a ResourceUpdate with Matter light device updates.
    static func matterUpdate(lights: [MatterLightDevice], devicesChanged: Bool = true) -> ResourceUpdate {
        ResourceUpdate(
            matterLights: lights,
            matterDevicesChanged: devicesChanged
        )
    }
}
