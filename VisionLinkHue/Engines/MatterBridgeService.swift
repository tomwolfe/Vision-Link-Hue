import Foundation
import HomeKit
import os

/// Service that manages Matter/Thread-based smart lighting as a fallback
/// when the Philips Hue Bridge is unavailable. Provides device discovery,
/// state management, and control commands through the HomeKit framework.
@MainActor
final class MatterBridgeService {
    
    // MARK: - State
    
    /// Whether HomeKit is available on this device.
    var isHomeKitAvailable: Bool { HMHomeManager.authorizationStatus == .authorized }
    
    /// Whether any Matter devices are currently connected and reachable.
    var hasReachableDevices: Bool { !reachableDevices.isEmpty }
    
    /// Whether Thread network is available.
    var isThreadNetworkAvailable: Bool {
        homes.contains { home in
            home.threadNetworkName != nil
        }
    }
    
    /// The current state of all Matter devices.
    var state: MatterBridgeState {
        let lights = homes.flatMap { home in
            home.accessories.compactMap { accessory in
                if accessory.isConnected && isLightAccessory(accessory) {
                    return MatterLightDevice.from(accessory: accessory)
                }
                return nil
            }
        }
        
        let borderRouters = homes.flatMap { home in
            home.accessories.compactMap { accessory in
                if accessory.isConnected {
                    return MatterBorderRouter(
                        id: accessory.accessoryIdentifier.uuidString,
                        name: accessory.name,
                        manufacturer: accessory.manufacturer,
                        model: accessory.model,
                        isOnline: true,
                        threadNetworkName: accessory.threadNetworkName
                    )
                }
                return nil
            }
        }
        
        return MatterBridgeState(
            lights: lights,
            borderRouters: borderRouters,
            threadNetworkAvailable: isThreadNetworkAvailable,
            lastUpdated: Date()
        )
    }
    
    /// All reachable Matter light devices.
    var reachableDevices: [MatterLightDevice] {
        state.lights.filter { $0.isReachable }
    }
    
    /// All homes known to the HomeKit manager.
    private var homes: [HMHome] = []
    
    /// Controllers for known Matter light devices.
    private var controllers: [String: any MatterLightController] = [:]
    
    /// HomeKit delegate observer.
    private weak var homeManager: HMHomeManager?
    
    /// Callback for device state changes.
    var onDeviceStateChanged: (@Sendable (MatterLightDevice) -> Void)?
    
    /// Callback for device reachability changes.
    var onReachabilityChanged: (@Sendable (String, Bool) -> Void)?
    
    // MARK: - Initialization
    
    init() {
        self.homeManager = HMHomeManager()
        self.homeManager?.delegate = self as? HMHomeManagerDelegate
    }
    
    // MARK: - Device Discovery
    
    /// Fetch all Matter devices from HomeKit.
    func fetchDevices() async throws -> MatterBridgeState {
        guard isHomeKitAvailable else {
            throw MatterError.homeKitNotAvailable
        }
        
        return state
    }
    
    /// Check if a specific Matter light is reachable and responsive.
    func isDeviceReachable(_ deviceId: String) async -> Bool {
        guard let controller = controllers[deviceId] else {
            return false
        }
        return controller.isReachable
    }
    
    // MARK: - Device Control
    
    /// Set the power state of a Matter light device.
    func setPower(deviceId: String, on: Bool) async throws {
        guard let controller = controller(for: deviceId) else {
            throw MatterError.accessoryNotReachable
        }
        try await controller.setPower(on)
    }
    
    /// Set the brightness of a Matter light device.
    func setBrightness(deviceId: String, brightness: Int, transitionDuration: Int = 4) async throws {
        guard let controller = controller(for: deviceId) else {
            throw MatterError.accessoryNotReachable
        }
        try await controller.setBrightness(brightness, transitionDuration: transitionDuration)
    }
    
    /// Set the color temperature of a Matter light device.
    func setColorTemperature(deviceId: String, mireds: Int, transitionDuration: Int = 4) async throws {
        guard let controller = controller(for: deviceId) else {
            throw MatterError.accessoryNotReachable
        }
        try await controller.setColorTemperature(mireds, transitionDuration: transitionDuration)
    }
    
    /// Set the XY color of a Matter light device.
    func setColorXY(deviceId: String, x: Double, y: Double, transitionDuration: Int = 4) async throws {
        guard let controller = controller(for: deviceId) else {
            throw MatterError.accessoryNotReachable
        }
        try await controller.setColorXY(x, y, transitionDuration: transitionDuration)
    }
    
    /// Patch a Matter light with multiple state changes.
    func patch(deviceId: String, patch: MatterLightStatePatch) async throws {
        guard let controller = controller(for: deviceId) else {
            throw MatterError.accessoryNotReachable
        }
        try await controller.patch(patch)
    }
    
    /// Refresh state for a specific Matter device.
    func refreshDeviceState(_ deviceId: String) async throws {
        guard let controller = controller(for: deviceId) else {
            throw MatterError.accessoryNotReachable
        }
        try await controller.refreshState()
    }
    
    // MARK: - Fallback Logic
    
    /// Determine if Matter should be used as the primary control path.
    /// Returns true when Hue Bridge is unavailable and Matter devices exist.
    func shouldUseMatterFallback(hueBridgeAvailable: Bool) -> Bool {
        guard !hueBridgeAvailable else { return false }
        return hasReachableDevices && isHomeKitAvailable
    }
    
    /// Get the preferred control path given Hue availability.
    /// Returns `.matter` when Hue is unavailable and Matter fallback is ready,
    /// `.hue` when the Hue Bridge is connected, or `.none` if neither is available.
    func preferredControlPath(hueBridgeAvailable: Bool) -> ControlPath {
        if hueBridgeAvailable {
            return .hue
        } else if shouldUseMatterFallback(hueBridgeAvailable: false) {
            return .matter
        } else {
            return .none
        }
    }
    
    // MARK: - Private Helpers
    
    private func controller(for deviceId: String) -> (any MatterLightController)? {
        if let existing = controllers[deviceId] {
            return existing
        }
        
        // Try to find the accessory in homes and create a controller
        for home in homes {
            if let accessory = home.accessories.first(where: {
                $0.accessoryIdentifier.uuidString == deviceId
            }) {
                Task { [weak self] in
                    do {
                        let controller = try await DefaultMatterLightController(home: home, accessory: accessory)
                        await self?.controllers[deviceId] = controller
                    } catch {
                        // Controller creation failed, will retry on next request
                    }
                }
                return nil
            }
        }
        
        return nil
    }
    
    private func isLightAccessory(_ accessory: HMAccessory) -> Bool {
        accessory.services.contains { service in
            service.characteristics.contains { char in
                char.type == HKCharacteristicType.characteristicTypeMQTTPowerState
            }
        }
    }
}

// MARK: - Control Path

/// Enumerates the possible control paths for lighting.
enum ControlPath: Sendable {
    /// Use the Philips Hue Bridge via CLIP v2 API.
    case hue
    /// Use Matter/Thread devices as fallback.
    case matter
    /// No control path is available.
    case none
}

// MARK: - HMHomeManagerDelegate Conformance

extension MatterBridgeService: HMHomeManagerDelegate {
    
    func homeManagerDidUpdateHomes(_ manager: HMHomeManager) {
        let previousReachability = hasReachableDevices
        homes = manager.homes
        
        // Notify state stream of device availability change
        if previousReachability != hasReachableDevices {
            // Devices reached or lost reachability
            for light in state.lights {
                onDeviceStateChanged?(light)
                onReachabilityChanged?(light.id, light.isReachable)
            }
        }
    }
    
    func homeManager(_ manager: HMHomeManager, didAdd homes: [HMHome]) {
        self.homes = manager.homes
    }
    
    func homeManager(_ manager: HMHomeManager, didRemove homes: [HMHome]) {
        self.homes = manager.homes
    }
    
    func homeManager(_ manager: HMHomeManager, didUpdateHomes homes: [HMHome]) {
        self.homes = homes
    }
}
