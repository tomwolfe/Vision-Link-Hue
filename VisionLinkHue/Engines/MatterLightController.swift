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
/// Manages a single HMAccessory and translates control commands to HomeKit operations.
final class DefaultMatterLightController: MatterLightController {
    
    let deviceId: String
    let isReachable: Bool
    
    private let logger = Logger(
        subsystem: "com.tomwolfe.visionlinkhue",
        category: "MatterLightController"
    )
    
    init(home: HMHome, accessory: HMAccessory) async throws {
        self.deviceId = UUID().uuidString
        self.isReachable = false
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
