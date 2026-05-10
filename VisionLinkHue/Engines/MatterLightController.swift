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
    
    private let lightbulbServiceType = "E863F10A-079E-48FF-8F27-9C2605A29F52"
    private let onCharacteristicType = "E863F10F-079E-48FF-8F27-9C2605A29F52"
    private let brightnessCharacteristicType = "E863F10D-079E-48FF-8F27-9C2605A29F52"
    private let colorTemperatureCharacteristicType = "E863F127-079E-48FF-8F27-9C2605A29F52"
    private let colorXYCharacteristicType = "E863F10F-079E-48FF-8F27-9C2605A29F52"
    
    init(home: HMHome, accessory: HMAccessory) async throws {
        self.home = home
        self.accessory = accessory
        self.deviceId = accessory.identifier.uuidString
        self.isReachable = accessory.isReachable
        
        guard let lightService = accessory.services.first(where: { $0.serviceType == lightbulbServiceType }) else {
            throw MatterError.noLightServiceFound
        }
        
        guard lightService.characteristics.contains(where: { $0.characteristicType == onCharacteristicType }) else {
            throw MatterError.noPowerCharacteristic
        }
    }
    
    private func onCharacteristic() throws -> HMCharacteristic {
        guard let lightService = accessory.services.first(where: { $0.serviceType == lightbulbServiceType }) else {
            throw MatterError.noLightServiceFound
        }
        guard let onChar = lightService.characteristics.first(where: { $0.characteristicType == onCharacteristicType }) else {
            throw MatterError.noPowerCharacteristic
        }
        return onChar
    }
    
    private func brightnessCharacteristic() throws -> HMCharacteristic {
        guard let lightService = accessory.services.first(where: { $0.serviceType == lightbulbServiceType }) else {
            throw MatterError.noLightServiceFound
        }
        guard let brightnessChar = lightService.characteristics.first(where: { $0.characteristicType == brightnessCharacteristicType }) else {
            throw MatterError.noBrightnessCharacteristic
        }
        return brightnessChar
    }
    
    private func colorTemperatureCharacteristic() throws -> HMCharacteristic {
        guard let lightService = accessory.services.first(where: { $0.serviceType == lightbulbServiceType }) else {
            throw MatterError.noLightServiceFound
        }
        guard let colorTempChar = lightService.characteristics.first(where: { $0.characteristicType == colorTemperatureCharacteristicType }) else {
            throw MatterError.noColorTemperatureCharacteristic
        }
        return colorTempChar
    }
    
    private func colorXYCharacteristic() throws -> HMCharacteristic {
        guard let lightService = accessory.services.first(where: { $0.serviceType == lightbulbServiceType }) else {
            throw MatterError.noLightServiceFound
        }
        guard let colorXYChar = lightService.characteristics.first(where: { $0.characteristicType == colorXYCharacteristicType }) else {
            throw MatterError.noColorTemperatureCharacteristic
        }
        return colorXYChar
    }
    
    func setPower(_ on: Bool) async throws {
        let char = try onCharacteristic()
        try await char.writeValue(on ? 1.0 : 0.0)
        isReachable = accessory.isReachable
    }
    
    func setBrightness(_ brightness: Int, transitionDuration: Int = 4) async throws {
        let char = try brightnessCharacteristic()
        let clampedBrightness = max(0, min(255, brightness))
        try await char.writeValue(Double(clampedBrightness) / 255.0 * 100.0)
        isReachable = accessory.isReachable
    }
    
    func setColorTemperature(_ mireds: Int, transitionDuration: Int = 4) async throws {
        let char = try colorTemperatureCharacteristic()
        let clampedTemp = max(0, min(10000, Double(mireds)))
        try await char.writeValue(clampedTemp)
        isReachable = accessory.isReachable
    }
    
    func setColorXY(_ x: Double, _ y: Double, transitionDuration: Int = 4) async throws {
        let char = try colorXYCharacteristic()
        try await char.writeValue([x, y])
        isReachable = accessory.isReachable
    }
    
    /// Minimum interval between characteristic writes to prevent flooding Thread network (100ms).
    private var lastWriteInstant: ContinuousClock.Instant = .now
    
    func patch(_ patch: MatterLightStatePatch) async throws {
        var actions: [() async throws -> Void] = []
        
        if let power = patch.power {
            if let char = try? onCharacteristic() {
                actions.append { try await char.writeValue(power ? 1.0 : 0.0) }
            }
        }
        if let brightness = patch.brightness {
            if let char = try? brightnessCharacteristic() {
                let clampedBrightness = max(0, min(255, brightness))
                actions.append { try await char.writeValue(Double(clampedBrightness) / 255.0 * 100.0) }
            }
        }
        if let colorTemperature = patch.colorTemperatureMireds {
            if let char = try? colorTemperatureCharacteristic() {
                actions.append { try await char.writeValue(Double(colorTemperature)) }
            }
        }
        if let colorX = patch.colorX, let colorY = patch.colorY {
            if let char = try? colorXYCharacteristic() {
                actions.append { try await char.writeValue([colorX, colorY]) }
            }
        }
        
        guard !actions.isEmpty else { return }
        
        let debounceInterval = Duration.milliseconds(100)
        let elapsed = ContinuousClock.now - lastWriteInstant
        if elapsed < debounceInterval {
            try await Task.sleep(for: debounceInterval - elapsed)
        }
        lastWriteInstant = .now
        
        for action in actions {
            try await action()
        }
        isReachable = accessory.isReachable
    }
    
    func refreshState() async throws {
        let onChar = try onCharacteristic()
        let brightnessChar = try brightnessCharacteristic()
        _ = onChar.value
        _ = brightnessChar.value
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
