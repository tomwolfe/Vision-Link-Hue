import Foundation
import HomeKit
import os

/// Protocol abstraction for Matter light device control.
/// Enables mocking in unit tests and decouples Matter communication from business logic.
@MainActor
protocol MatterLightController: AnyObject, Sendable {
    
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
/// Manages a single HMAccessory and translates control commands to HomeKit operation
final class DefaultMatterLightController: MatterLightController {
    
    let deviceId: String
    let isReachable: Bool
    
    private let home: HMHome
    private let accessory: HMAccessory
    private let logger = Logger(
        subsystem: "com.tomwolfe.visionlinkhue",
        category: "MatterLightController"
    )
    
    /// Cached light service reference for the accessory.
    private weak var lightService: AnyObject?
    
    init(home: HMHome, accessory: HMAccessory) async throws {
        self.home = home
        self.accessory = accessory
        self.deviceId = accessory.displayName ?? UUID().uuidString
        self.isReachable = accessory.reachable
        
        logger.info("Initialized MatterLightController for accessory: \(accessory.displayName ?? "Unknown")")
    }
    
    deinit {
    }
    
    func setPower(_ on: Bool) async throws {
        guard let switchService = findService(type: .onOff) else {
            throw MatterError.noPowerCharacteristic
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            switchService.setTargetOn(on) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }
    
    func setBrightness(_ brightness: Int, transitionDuration: Int = 4) async throws {
        guard brightness >= 0 && brightness <= 255 else {
            throw MatterError.invalidCharacteristicValue
        }
        
        guard let brightnessService = findService(type: .brightness) else {
            throw MatterError.noBrightnessCharacteristic
        }
        
        let normalizedBrightness = Double(brightness) / 255.0
        
        return try await withCheckedThrowingContinuation { continuation in
            brightnessService.setTargetBrightness(normalizedBrightness) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }
    
    func setColorTemperature(_ mireds: Int, transitionDuration: Int = 4) async throws {
        guard mireds >= 0 else {
            throw MatterError.invalidCharacteristicValue
        }
        
        guard let colorTempService = findService(type: .colorTemperature) else {
            throw MatterError.noColorTemperatureCharacteristic
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            colorTempService.setTargetColorTemperature(Double(mireds)) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }
    
    func setColorXY(_ x: Double, _ y: Double, transitionDuration: Int = 4) async throws {
        guard (0...1).contains(x) && (0...1).contains(y) else {
            throw MatterError.invalidCharacteristicValue
        }
        
        guard let colorService = findService(type: .color) else {
            throw MatterError.invalidCharacteristicValue
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            colorService.setTargetColorX(Int(x * 65535.0)) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }
    
    func patch(_ patch: MatterLightStatePatch) async throws {
        if let power = patch.power {
            try await setPower(power)
        }
        
        if let brightness = patch.brightness {
            try await setBrightness(brightness, transitionDuration: patch.transitionDuration ?? 4)
        }
        
        if let colorTemperature = patch.colorTemperatureMireds {
            try await setColorTemperature(colorTemperature, transitionDuration: patch.transitionDuration ?? 4)
        }
        
        if let colorX = patch.colorX, let colorY = patch.colorY {
            try await setColorXY(colorX, colorY, transitionDuration: patch.transitionDuration ?? 4)
        }
    }
    
    func refreshState() async throws {
        guard let switchService = findService(type: .onOff) else { return }
        
        try await withCheckedThrowingContinuation { continuation in
            switchService.on { currentValue, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }
    
    // MARK: - Private Helpers
    
    /// Find a HomeKit service on the accessory by type.
    /// Uses iOS 26 expanded HomeKit Matter cluster APIs for direct service access.
    private func findService(type: MatterServiceType) -> AnyObject? {
        guard accessory.services.isEmpty == false else { return nil }
        
        switch type {
        case .onOff:
            return accessory.services.first { $0.isSupported && $0.characteristics.contains { $0.serviceType == "89" } }
        case .brightness:
            return accessory.services.first { $0.isSupported && $0.characteristics.contains { $0.serviceType == "8A" } }
        case .colorTemperature:
            return accessory.services.first { $0.isSupported && $0.characteristics.contains { $0.serviceType == "CB" } }
        case .color:
            return accessory.services.first { $0.isSupported && $0.characteristics.contains { $0.serviceType == "CC" } }
        }
    }
}

// MARK: - Matter Service Type

/// Maps Matter Light Bulb cluster types to HomeKit service types.
/// iOS 26 uses expanded HomeKit Matter cluster APIs rather than legacy characteristic UUIDs.
private enum MatterServiceType {
    case onOff
    case brightness
    case colorTemperature
    case color
}
    
    deinit {
    }
    
    func setPower(_ on: Bool) async throws {
        throw MatterError.homeKitNotAvailable
    }
    
    func setBrightness(_ brightness: Int, transitionDuration: Int = 4) async throws {
        throw MatterError.homeKitNotAvailable
    }
    
    func setColorTemperature(_ mireds: Int, transitionDuration: Int = 4) async throws {
        throw MatterError.homeKitNotAvailable
    }
    
    func setColorXY(_ x: Double, _ y: Double, transitionDuration: Int = 4) async throws {
        throw MatterError.homeKitNotAvailable
    }
    
    func patch(_ patch: MatterLightStatePatch) async throws {
        throw MatterError.homeKitNotAvailable
    }
    
    func refreshState() async throws {
        throw MatterError.homeKitNotAvailable
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
