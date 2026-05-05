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
/// characteristics (On/Off, Brightness, Color Temperature, Color XY).
final class DefaultMatterLightController: MatterLightController {
    
    let deviceId: String
    var isReachable: Bool
    
    private let accessory: HMAccessory
    private let home: HMHome
    private let logger = Logger(subsystem: "com.tomwolfe.visionlinkhue", category: "MatterLightController")
    
    init(home: HMHome, accessory: HMAccessory) async throws {
        self.home = home
        self.accessory = accessory
        self.deviceId = accessory.identifier.uuidString
        self.isReachable = accessory.isReachable
        
        guard let lightService = accessory.services.first(where: { $0.serviceType == .lightbulb }) else {
            throw MatterError.noLightServiceFound
        }
        
        guard lightService.characteristics.contains(where: { $0.characteristicType == .on }) else {
            throw MatterError.noPowerCharacteristic
        }
    }
    
    private func onCharacteristic() throws -> HMCharacteristic {
        guard let lightService = accessory.services.first(where: { $0.serviceType == .lightbulb }) else {
            throw MatterError.noLightServiceFound
        }
        guard let onChar = lightService.characteristics.first(where: { $0.characteristicType == .on }) else {
            throw MatterError.noPowerCharacteristic
        }
        return onChar
    }
    
    private func brightnessCharacteristic() throws -> HMCharacteristic {
        guard let lightService = accessory.services.first(where: { $0.serviceType == .lightbulb }) else {
            throw MatterError.noLightServiceFound
        }
        guard let brightnessChar = lightService.characteristics.first(where: { $0.characteristicType == .brightness }) else {
            throw MatterError.noBrightnessCharacteristic
        }
        return brightnessChar
    }
    
    private func colorTemperatureCharacteristic() throws -> HMCharacteristic {
        guard let lightService = accessory.services.first(where: { $0.serviceType == .lightbulb }) else {
            throw MatterError.noLightServiceFound
        }
        guard let colorTempChar = lightService.characteristics.first(where: { $0.characteristicType == .colorTemperature }) else {
            throw MatterError.noColorTemperatureCharacteristic
        }
        return colorTempChar
    }
    
    private func colorXYCharacteristic() throws -> HMCharacteristic {
        guard let lightService = accessory.services.first(where: { $0.serviceType == .lightbulb }) else {
            throw MatterError.noLightServiceFound
        }
        guard let colorXYChar = lightService.characteristics.first(where: { $0.characteristicType == .colorXY }) else {
            throw MatterError.noColorTemperatureCharacteristic
        }
        return colorXYChar
    }
    
    func setPower(_ on: Bool) async throws {
        let char = try onCharacteristic()
        try await home.performWaitForAccess(characteristics: [char]) { completion in
            char.writeValue(on ? 1.0 : 0.0, for: { _ in completion(nil) })
        }
        isReachable = accessory.isReachable
    }
    
    func setBrightness(_ brightness: Int, transitionDuration: Int = 4) async throws {
        let char = try brightnessCharacteristic()
        let clampedBrightness = max(0, min(255, brightness))
        try await home.performWaitForAccess(characteristics: [char]) { completion in
            char.writeValue(Double(clampedBrightness) / 255.0 * 100.0, for: { _ in completion(nil) })
        }
        isReachable = accessory.isReachable
    }
    
    func setColorTemperature(_ mireds: Int, transitionDuration: Int = 4) async throws {
        let char = try colorTemperatureCharacteristic()
        guard let minTemp = char.minimumValue, let maxTemp = char.maximumValue else {
            throw MatterError.noColorTemperatureCharacteristic
        }
        let clampedTemp = max(minTemp, min(Double(mireds), maxTemp))
        try await home.performWaitForAccess(characteristics: [char]) { completion in
            char.writeValue(clampedTemp, for: { _ in completion(nil) })
        }
        isReachable = accessory.isReachable
    }
    
    func setColorXY(_ x: Double, _ y: Double, transitionDuration: Int = 4) async throws {
        let char = try colorXYCharacteristic()
        try await home.performWaitForAccess(characteristics: [char]) { completion in
            char.writeValue([x, y], for: { _ in completion(nil) })
        }
        isReachable = accessory.isReachable
    }
    
    func patch(_ patch: MatterLightStatePatch) async throws {
        var characteristics: [HMCharacteristic] = []
        
        if let power = patch.power {
            characteristics.append(try onCharacteristic())
        }
        if let brightness = patch.brightness {
            characteristics.append(try brightnessCharacteristic())
        }
        if let colorTemperature = patch.colorTemperature {
            characteristics.append(try colorTemperatureCharacteristic())
        }
        if let xy = patch.colorXY {
            characteristics.append(try colorXYCharacteristic())
        }
        
        guard !characteristics.isEmpty else { return }
        
        try await home.performWaitForAccess(characteristics: characteristics) { completion in
            var writeActions: [() -> Void] = []
            
            if let power = patch.power {
                if let char = characteristics.first(where: { $0.characteristicType == .on }) {
                    writeActions.append { char.writeValue(power ? 1.0 : 0.0, for: { _ in }) }
                }
            }
            if let brightness = patch.brightness {
                if let char = characteristics.first(where: { $0.characteristicType == .brightness }) {
                    writeActions.append {
                        let clampedBrightness = max(0, min(255, brightness))
                        char.writeValue(Double(clampedBrightness) / 255.0 * 100.0, for: { _ in })
                    }
                }
            }
            if let colorTemperature = patch.colorTemperature {
                if let char = characteristics.first(where: { $0.characteristicType == .colorTemperature }) {
                    writeActions.append { char.writeValue(Double(colorTemperature), for: { _ in }) }
                }
            }
            if let xy = patch.colorXY {
                if let char = characteristics.first(where: { $0.characteristicType == .colorXY }) {
                    writeActions.append { char.writeValue([xy.x, xy.y], for: { _ in }) }
                }
            }
            
            for action in writeActions {
                action()
            }
            completion(nil)
        }
        isReachable = accessory.isReachable
    }
    
    func refreshState() async throws {
        try await home.performWaitForAccess(characteristics: [
            try onCharacteristic(),
            try brightnessCharacteristic()
        ]) { completion in
            completion(nil)
        }
        isReachable = accessory.isReachable
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
