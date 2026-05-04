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
                    let areaMetadata = MatterBridgeService.extractAreaMetadata(from: accessory)
                    return MatterBorderRouter(
                        id: accessory.accessoryIdentifier.uuidString,
                        name: accessory.name,
                        manufacturer: accessory.manufacturer,
                        model: accessory.model,
                        isOnline: true,
                        threadNetworkName: accessory.threadNetworkName,
                        rssi: nil,
                        areaMetadata: areaMetadata
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
    
    // MARK: - Matter Area Metadata (Matter 1.5.1+)
    
    /// Import area metadata from all connected Thread Border Routers.
    /// This provides room/area definitions that can pre-populate light groups
    /// when the Hue Bridge is offline, per Matter 1.5.1 specification.
    func importAreaMetadata() async -> [MatterAreaMetadata] {
        var areas: [MatterAreaMetadata] = []
        
        for router in state.borderRouters {
            if let metadata = router.areaMetadata {
                areas.append(metadata)
            }
        }
        
        if !areas.isEmpty {
            logger.info("Imported \(areas.count) area(s) from \(state.borderRouters.count) Thread Border Router(s)")
        }
        
        return areas
    }
    
    /// Get area metadata for a specific light device from the Matter network.
    /// Returns the area assignment if the light is part of a Matter-defined area.
    func areaForLight(_ lightId: String) -> MatterAreaMetadata? {
        for router in state.borderRouters {
            if let metadata = router.areaMetadata {
                if metadata.assignedLightIds.contains(lightId) {
                    return metadata
                }
                // Check child areas
                for childAreaId in metadata.childAreaIds {
                    if let child = areaById(childAreaId) {
                        if child.assignedLightIds.contains(lightId) {
                            return child
                        }
                    }
                }
            }
        }
        return nil
    }
    
    /// Get all area metadata indexed by area ID for quick lookup.
    func allAreaMetadata() -> [String: MatterAreaMetadata] {
        var result: [String: MatterAreaMetadata] = [:]
        
        for router in state.borderRouters {
            if let metadata = router.areaMetadata {
                result[metadata.areaId] = metadata
            }
        }
        
        return result
    }
    
    /// Pre-populate light group assignments from Matter area metadata.
    /// This is called when the Hue Bridge is offline to provide room-aware
    /// light grouping based on Matter network topology.
    func prePopulateLightGroups() async -> [String: [String]] {
        // Returns a mapping of areaId -> [lightIds]
        var groups: [String: [String]] = [:]
        
        for router in state.borderRouters {
            if let metadata = router.areaMetadata {
                groups[metadata.areaId] = metadata.assignedLightIds
            }
        }
        
        return groups
    }
    
    private func areaById(_ areaId: String) -> MatterAreaMetadata? {
        for router in state.borderRouters {
            if let metadata = router.areaMetadata {
                if metadata.areaId == areaId {
                    return metadata
                }
                for childAreaId in metadata.childAreaIds {
                    if childAreaId == areaId {
                        return MatterAreaMetadata(
                            areaId: childAreaId,
                            areaName: "\(metadata.areaName) (sub-area)",
                            childAreaIds: [],
                            assignedLightIds: []
                        )
                    }
                }
            }
        }
        return nil
    }
    
    // MARK: - Private Helpers
    
    /// Extract area metadata from a HomeKit accessory (Matter 1.5.1+).
    /// Looks for Matter Area and Zone information in the accessory's services.
    private static func extractAreaMetadata(from accessory: HMAccessory) -> MatterAreaMetadata? {
        // Matter 1.5.1 adds Area and Zone information as accessory metadata
        // This is exposed through HMAccessory's extended properties
        guard let areaData = accessory.userData as? [String: Any],
              let areaId = areaData["matterAreaId"] as? String,
              let areaName = areaData["matterAreaName"] as? String else {
            return nil
        }
        
        let childAreaIds = (areaData["matterChildAreaIds"] as? [String]) ?? []
        let assignedLightIds = (areaData["matterAssignedLightIds"] as? [String]) ?? []
        
        return MatterAreaMetadata(
            areaId: areaId,
            areaName: areaName,
            childAreaIds: childAreaIds,
            assignedLightIds: assignedLightIds
        )
    }
    
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
