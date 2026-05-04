import Foundation
import HomeKit
import os

// MARK: - Matter Device Models

/// Unified Matter device type enumeration covering all Matter light clusters.
enum MatterDeviceType: String, Sendable, CaseIterable {
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
struct MatterLightDevice: Identifiable, Sendable {
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
    
    init(
        id: String,
        name: String,
        deviceType: MatterDeviceType,
        manufacturerName: String,
        modelIdentifier: String,
        firmwareVersion: String,
        isReachable: Bool,
        powerState: Bool,
        brightness: Int,
        colorTemperatureMireds: Int? = nil,
        colorX: Double? = nil,
        colorY: Double? = nil,
        threadNetworkName: String? = nil,
        commissioningMode: Int = 0
    ) {
        self.id = id
        self.name = name
        self.deviceType = deviceType
        self.manufacturerName = manufacturerName
        self.modelIdentifier = modelIdentifier
        self.firmwareVersion = firmwareVersion
        self.isReachable = isReachable
        self.powerState = powerState
        self.brightness = brightness
        self.colorTemperatureMireds = colorTemperatureMireds
        self.colorX = colorX
        self.colorY = colorY
        self.threadNetworkName = threadNetworkName
        self.commissioningMode = commissioningMode
    }
    
    /// Convert from a HomeKit accessory to a MatterLightDevice.
    static func from(accessory: HMAccessory) -> MatterLightDevice {
        let deviceType = MatterLightDevice.inferDeviceType(from: accessory)
        let service = MatterLightDevice.primaryLightService(for: accessory)
        
        var powerState = false
        var brightness = 0
        var colorTemp: Int? = nil
        var colorX: Double? = nil
        var colorY: Double? = nil
        
        if let service = service {
            if let onOffState = service.characteristics.first(where: { $0.type == HKCharacteristicType.characteristicTypeMQTTPowerState }) {
                powerState = (onOffState.value as? Bool) ?? false
            }
            if let brightnessValue = service.characteristics.first(where: { $0.type == HKCharacteristicType.characteristicTypeMQTTBrightness }) {
                brightness = (brightnessValue.value as? Int) ?? 0
            }
            if let ctValue = service.characteristics.first(where: { $0.type == HKCharacteristicType.characteristicTypeMQTTColorTemperature }) {
                colorTemp = (ctValue.value as? Int) ?? nil
            }
            if let cxValue = service.characteristics.first(where: { $0.type == HKCharacteristicType.characteristicTypeMQTTColorX }) {
                colorX = (cxValue.value as? Double) ?? nil
            }
            if let cyValue = service.characteristics.first(where: { $0.type == HKCharacteristicType.characteristicTypeMQTTColorY }) {
                colorY = (cyValue.value as? Double) ?? nil
            }
        }
        
        return MatterLightDevice(
            id: accessory.accessoryIdentifier.uuidString,
            name: accessory.name,
            deviceType: deviceType,
            manufacturerName: accessory.manufacturer,
            modelIdentifier: accessory.model,
            firmwareVersion: accessory.revisionString,
            isReachable: accessory.isConnected,
            powerState: powerState,
            brightness: brightness,
            colorTemperatureMireds: colorTemp,
            colorX: colorX,
            colorY: colorY,
            threadNetworkName: accessory.threadNetworkName,
            commissioningMode: accessory.commissioningMode
        )
    }
    
    private static func inferDeviceType(from accessory: HMAccessory) -> MatterDeviceType {
        let service = primaryLightService(for: accessory)
        guard let service = service else { return .unknown }
        
        let hasColorTemp = service.characteristics.contains { $0.type == HKCharacteristicType.characteristicTypeMQTTColorTemperature }
        let hasColorXY = service.characteristics.contains { $0.type == HKCharacteristicType.characteristicTypeMQTTColorX }
        
        if hasColorTemp || hasColorXY {
            return .extendedColorLight
        } else if hasColorTemp {
            return .colorTemperatureLight
        } else if service.characteristics.contains(where: { $0.type == HKCharacteristicType.characteristicTypeMQTTBrightness }) {
            return .dimmableLight
        } else {
            return .onOffLight
        }
    }
    
    private static func primaryLightService(for accessory: HMAccessory) -> HMService? {
        accessory.services.first { service in
            service.characteristics.contains { char in
                char.type == HKCharacteristicType.characteristicTypeMQTTPowerState
            }
        }
    }
}

// MARK: - Matter Bridge/Controller Models

/// Represents a Matter Thread border router or controller that can serve as a fallback lighting gateway.
struct MatterBorderRouter: Identifiable, Sendable {
    let id: String
    let name: String
    let manufacturer: String
    let model: String
    let isOnline: Bool
    let threadNetworkName: String?
    let rssi: Int?
    
    init(
        id: String,
        name: String,
        manufacturer: String,
        model: String,
        isOnline: Bool,
        threadNetworkName: String? = nil,
        rssi: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.manufacturer = manufacturer
        self.model = model
        self.isOnline = isOnline
        self.threadNetworkName = threadNetworkName
        self.rssi = rssi
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
struct MatterEvent: Sendable {
    let type: MatterEventType
    let deviceId: String
    let timestamp: Date
    let changes: [String: Any]
    
    init(
        type: MatterEventType,
        deviceId: String,
        timestamp: Date = Date(),
        changes: [String: Any] = [:]
    ) {
        self.type = type
        self.deviceId = deviceId
        self.timestamp = timestamp
        self.changes = changes
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
    
    /// Convenience accessor for Matter lights from the codable property.
    var matterLights: [MatterLightDevice]? {
        matterLights
    }
    
    /// Convenience accessor for Matter devices changed flag.
    var matterDevicesChanged: Bool {
        matterDevicesChanged
    }
}
