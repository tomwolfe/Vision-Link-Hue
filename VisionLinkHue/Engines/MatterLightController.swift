import Foundation
import HomeKit
import os

/// Protocol abstraction for Matter light device control.
/// Enables mocking in unit tests and decouples Matter communication from business logic.
@MainActor
protocol MatterLightController: AnyObject {
    
    /// The unique identifier for this Matter light device.
    var deviceId: String { get }
    
    /// Whether the device is currently reachable.
    var isReachable: Bool { get }
    
    /// Control the power state of the device.
    func setPower(_ on: Bool) async throws
    
    /// Control the brightness of the device (0-255).
    func setBrightness(_ brightness: Int, transitionDuration: Int) async throws
    
    /// Control the color temperature (mireds).
    func setColorTemperature(_ mireds: Int, transitionDuration: Int) async throws
    
    /// Control the color via XY coordinates.
    func setColorXY(_ x: Double, _ y: Double, transitionDuration: Int) async throws
    
    /// Execute a batch patch with multiple state changes.
    func patch(_ patch: MatterLightStatePatch) async throws
    
    /// Refresh the current state from the device.
    func refreshState() async throws
}

/// Default implementation of MatterLightController backed by HomeKit.
/// Manages a single HMAccessory and translates control commands to HomeKit operations.
@MainActor
final class DefaultMatterLightController: MatterLightController {
    
    let deviceId: String
    let isReachable: Bool
    
    private let logger = Logger(
        subsystem: "com.tomwolfe.visionlinkhue",
        category: "MatterLightController"
    )
    
    private let home: HMHome
    private let accessory: HMAccessory
    
    init(home: HMHome, accessory: HMAccessory) async throws {
        self.home = home
        self.accessory = accessory
        self.deviceId = accessory.accessoryIdentifier.uuidString
        self.isReachable = accessory.isConnected
        
        try await home.retrievePeripheralsAndConnect()
    }
    
    deinit {
        Task { [home, accessory] in
            await home.retrievePeripheralsAndDisconnect([accessory])
        }
    }
    
    func setPower(_ on: Bool) async throws {
        guard let service = primaryLightService else {
            throw MatterError.noLightServiceFound
        }
        
        guard let powerCharacteristic = service.characteristics.first(where: {
            $0.type == HKCharacteristicType.characteristicTypeMQTTPowerState
        }) else {
            throw MatterError.noPowerCharacteristic
        }
        
        try await accessory.updateCharacteristic(powerCharacteristic, value: on)
        logger.info("Set power to \(on) for device \(deviceId)")
    }
    
    func setBrightness(_ brightness: Int, transitionDuration: Int = 4) async throws {
        guard let service = primaryLightService else {
            throw MatterError.noLightServiceFound
        }
        
        guard let brightnessCharacteristic = service.characteristics.first(where: {
            $0.type == HKCharacteristicType.characteristicTypeMQTTBrightness
        }) else {
            throw MatterError.noBrightnessCharacteristic
        }
        
        try await accessory.updateCharacteristic(brightnessCharacteristic, value: brightness)
        logger.info("Set brightness to \(brightness) for device \(deviceId)")
    }
    
    func setColorTemperature(_ mireds: Int, transitionDuration: Int = 4) async throws {
        guard let service = primaryLightService else {
            throw MatterError.noLightServiceFound
        }
        
        guard let ctCharacteristic = service.characteristics.first(where: {
            $0.type == HKCharacteristicType.characteristicTypeMQTTColorTemperature
        }) else {
            throw MatterError.noColorTemperatureCharacteristic
        }
        
        try await accessory.updateCharacteristic(ctCharacteristic, value: mireds)
        logger.info("Set color temperature to \(mireds) mireds for device \(deviceId)")
    }
    
    func setColorXY(_ x: Double, _ y: Double, transitionDuration: Int = 4) async throws {
        guard let service = primaryLightService else {
            throw MatterError.noLightServiceFound
        }
        
        if let xCharacteristic = service.characteristics.first(where: {
            $0.type == HKCharacteristicType.characteristicTypeMQTTColorX
        }) {
            try await accessory.updateCharacteristic(xCharacteristic, value: x)
        }
        
        if let yCharacteristic = service.characteristics.first(where: {
            $0.type == HKCharacteristicType.characteristicTypeMQTTColorY
        }) {
            try await accessory.updateCharacteristic(yCharacteristic, value: y)
        }
        
        logger.info("Set color XY (\(x), \(y)) for device \(deviceId)")
    }
    
    func patch(_ patch: MatterLightStatePatch) async throws {
        if let power = patch.power {
            try await setPower(power)
        }
        
        if let brightness = patch.brightness {
            try await setBrightness(brightness, transitionDuration: patch.transitionDuration ?? 4)
        }
        
        if let ct = patch.colorTemperatureMireds {
            try await setColorTemperature(ct, transitionDuration: patch.transitionDuration ?? 4)
        }
        
        if let x = patch.colorX, let y = patch.colorY {
            try await setColorXY(x, y, transitionDuration: patch.transitionDuration ?? 4)
        }
    }
    
    func refreshState() async throws {
        try await home.updateRefresh()
        logger.debug("Refreshed state for device \(deviceId)")
    }
    
    private var primaryLightService: HMService? {
        accessory.services.first { service in
            service.characteristics.contains { char in
                char.type == HKCharacteristicType.characteristicTypeMQTTPowerState
            }
        }
    }
}

// MARK: - Matter Error Types

enum MatterError: Error, LocalizedError {
    case noLightServiceFound
    case noPowerCharacteristic
    case noBrightnessCharacteristic
    case noColorTemperatureCharacteristic
    case accessoryNotReachable
    case homeKitNotAvailable
    case commissioningFailed
    case threadNetworkUnavailable
    case invalidCharacteristicValue
    
    var errorDescription: String? {
        switch self {
        case .noLightServiceFound:
            return "No light service found on the Matter accessory"
        case .noPowerCharacteristic:
            return "No power control characteristic available"
        case .noBrightnessCharacteristic:
            return "No brightness control characteristic available"
        case .noColorTemperatureCharacteristic:
            return "No color temperature control characteristic available"
        case .accessoryNotReachable:
            return "Matter accessory is not reachable"
        case .homeKitNotAvailable:
            return "HomeKit is not available on this device"
        case .commissioningFailed:
            return "Failed to commission Matter accessory"
        case .threadNetworkUnavailable:
            return "Thread network is not available"
        case .invalidCharacteristicValue:
            return "Invalid characteristic value"
        }
    }
}
