import Foundation
@preconcurrency import HomeKit
import os

/// Service that manages Matter/Thread-based smart lighting as a fallback
/// when the Philips Hue Bridge is unavailable. Provides device discovery,
/// state management, and control commands through the HomeKit framework.
///
/// Implements a dual-path control strategy: Matter/Thread devices are the
/// primary path, with automatic fallback to the Hue Bridge CLIP v2 API when
/// Matter accessories are unreachable or unavailable.
final class MatterBridgeService: NSObject, @unchecked Sendable {
    
    // MARK: - State
    
    private let logger = Logger(
        subsystem: "com.tomwolfe.visionlinkhue",
        category: "MatterBridge"
    )
    
    /// Whether HomeKit is available on this device.
    var isHomeKitAvailable: Bool { homeManager?.authorizationStatus == .authorized }
    
    /// Whether any Matter devices are currently connected and reachable.
    var hasReachableDevices: Bool { !reachableDevices.isEmpty }
    
    /// Whether Thread network is available.
    var isThreadNetworkAvailable: Bool { !borderRouters.filter(\.isOnline).isEmpty }
    
    /// The current state of all Matter devices, populated from HomeKit accessories.
    var state: MatterBridgeState {
        let lights = reachableDevices
        let threadAvailable = isThreadNetworkAvailable
        return MatterBridgeState(
            lights: lights,
            borderRouters: borderRouters,
            threadNetworkAvailable: threadAvailable,
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
    
    /// Border routers discovered via MultipeerConnectivity.
    private var borderRouters: [MatterBorderRouter] = []
    
    /// HomeKit delegate observer.
    private weak var homeManager: HMHomeManager?
    
    /// Optional reference to the Hue client for fallback control.
    private weak var hueClient: HueClientProtocol?
    
    /// Callback for device state changes.
    var onDeviceStateChanged: (@Sendable (MatterLightDevice) -> Void)?
    
    /// Callback for device reachability changes.
    var onReachabilityChanged: (@Sendable (String, Bool) -> Void)?
    
    // MARK: - Initialization
    
    override init() {
        super.init()
        self.homeManager = HMHomeManager()
        self.homeManager?.delegate = self as? HMHomeManagerDelegate
    }
    
    /// Initialize with an optional Hue client reference for fallback control.
    /// - Parameters:
    ///   - hueClient: Optional Hue client for fallback when Matter is unavailable.
    init(hueClient: HueClientProtocol?) {
        super.init()
        self.homeManager = HMHomeManager()
        self.homeManager?.delegate = self as? HMHomeManagerDelegate
        self.hueClient = hueClient
    }
    
    // MARK: - Device Discovery
    
    /// Fetch all Matter devices from HomeKit, populating the state from
    /// registered HomeKit accessories.
    func fetchDevices() async throws -> MatterBridgeState {
        guard isHomeKitAvailable else {
            throw MatterError.homeKitNotAvailable
        }
        
        await updateDeviceState()
        return state
    }
    
    /// Update the device state by scanning all HomeKit accessories.
    private func updateDeviceState() async {
        await MainActor.run { [weak self] in
            guard let self else { return }
            self.homes = self.homeManager?.homes ?? []
        }
        
        var discoveredLights: [MatterLightDevice] = []
        
        for home in homes {
            for accessory in home.accessories {
                guard accessory.isReachable else { continue }
                
                let hasLightService = accessory.services.contains { service in
                    service.serviceType == .lightbulb
                }
                
                guard hasLightService else { continue }
                
                let isOn = await MainActor.run {
                    accessory.services.first(where: { $0.serviceType == .lightbulb })?
                        .characteristics.first(where: { $0.characteristicType == .on })?
                        .int_value == 1
                } ?? false
                
                let brightness = await MainActor.run {
                    accessory.services.first(where: { $0.serviceType == .lightbulb })?
                        .characteristics.first(where: { $0.characteristicType == .brightness })?
                        .int_value ?? 0
                }
                
                let device = MatterLightDevice(
                    id: accessory.identifier.uuidString,
                    name: accessory.name ?? "Unknown Device",
                    deviceType: .extendedColorLight,
                    manufacturerName: accessory.manufacturer ?? "Unknown",
                    modelIdentifier: accessory.model ?? "Unknown",
                    firmwareVersion: "",
                    isReachable: accessory.isReachable,
                    powerState: isOn,
                    brightness: brightness,
                    colorTemperatureMireds: nil,
                    colorX: nil,
                    colorY: nil,
                    threadNetworkName: nil,
                    commissioningMode: 0
                )
                
                discoveredLights.append(device)
            }
        }
        
        await MainActor.run { [weak self, discoveredLights] in
            guard let self else { return }
            self.controllers.removeAll()
            for device in discoveredLights {
                self.controllers[device.id] = nil
            }
            self.onDeviceStateChanged?(MatterLightDevice(
                id: "", name: "", deviceType: .unknown,
                manufacturerName: "", modelIdentifier: "",
                firmwareVersion: "", isReachable: false,
                powerState: false, brightness: 0,
                colorTemperatureMireds: nil, colorX: nil, colorY: nil,
                threadNetworkName: nil, commissioningMode: 0
            ))
        }
    }
    
    /// Check if a specific Matter light is reachable and responsive.
    func isDeviceReachable(_ deviceId: String) async -> Bool {
        guard let controller = controllers[deviceId] else {
            return false
        }
        return await MainActor.run { controller.isReachable } ?? false
    }
    
    // MARK: - Device Control
    
    /// Turn a Matter light on or off, with automatic fallback to Hue Bridge
    /// if Matter control is unavailable.
    func toggle(deviceId: String, on: Bool) async throws {
        do {
            guard let controller = controller(for: deviceId) else {
                throw MatterError.accessoryNotReachable
            }
            try await controller.setPower(on)
            logger.debug("Toggled Matter light \(deviceId) to \(on ? "on" : "off")")
        } catch {
            logger.debug("Matter control failed for \(deviceId)}, falling back to Hue Bridge: \(error.localizedDescription)")
            guard let hueClient else {
                throw MatterError.noLightServiceFound
            }
            try await hueClient.togglePower(resourceId: deviceId, on: on)
        }
    }
    
    /// Set the brightness of a Matter light, with automatic fallback to Hue Bridge.
    func setBrightness(_ brightness: Double, deviceId: String, transitionDuration: TimeInterval = 0.5) async throws {
        do {
            guard let controller = controller(for: deviceId) else {
                throw MatterError.accessoryNotReachable
            }
            try await controller.setBrightness(Int(brightness * 255), transitionDuration: Int(transitionDuration * 10))
            logger.debug("Set brightness of Matter light \(deviceId) to \(brightness)")
        } catch {
            logger.debug("Matter brightness control failed for \(deviceId}, falling back to Hue Bridge: \(error.localizedDescription)")
            guard let hueClient else {
                throw MatterError.noLightServiceFound
            }
            try await hueClient.setBrightness(resourceId: deviceId, brightness: Int(brightness * 255), transitionDuration: Int(transitionDuration * 10))
        }
    }
    
    /// Set the color temperature of a Matter light, with automatic fallback to Hue Bridge.
    func setColorTemperature(_ temperature: Double, deviceId: String, transitionDuration: TimeInterval = 0.5) async throws {
        do {
            guard let controller = controller(for: deviceId) else {
                throw MatterError.accessoryNotReachable
            }
            try await controller.setColorTemperature(Int(temperature), transitionDuration: Int(transitionDuration * 10))
            logger.debug("Set color temperature of Matter light \(deviceId) to \(temperature)")
        } catch {
            logger.debug("Matter color temperature control failed for \(deviceId}, falling back to Hue Bridge: \(error.localizedDescription)")
            guard let hueClient else {
                throw MatterError.noLightServiceFound
            }
            try await hueClient.setColorTemperature(resourceId: deviceId, mireds: Int(temperature), transitionDuration: Int(transitionDuration * 10))
        }
    }
    
    /// Set the color of a Matter light using XY coordinates, with automatic fallback to Hue Bridge.
    func setColorX(_ x: Double, _ y: Double, deviceId: String, transitionDuration: TimeInterval = 0.5) async throws {
        do {
            guard let controller = controller(for: deviceId) else {
                throw MatterError.accessoryNotReachable
            }
            try await controller.setColorXY(x, y, transitionDuration: Int(transitionDuration * 10))
            logger.debug("Set color XY of Matter light \(deviceId) to (\(x), \(y))")
        } catch {
            logger.debug("Matter color control failed for \(deviceId}, falling back to Hue Bridge: \(error.localizedDescription)")
            guard let hueClient else {
                throw MatterError.noLightServiceFound
            }
            try await hueClient.setColorXY(resourceId: deviceId, x: x, y: y, transitionDuration: Int(transitionDuration * 10))
        }
    }
    
    /// Patch a Matter light with multiple state changes, with automatic fallback to Hue Bridge.
    func patch(deviceId: String, patch: MatterLightStatePatch) async throws {
        do {
            guard let controller = controller(for: deviceId) else {
                throw MatterError.accessoryNotReachable
            }
            try await controller.patch(patch)
            logger.debug("Patched Matter light \(deviceId)")
        } catch {
            logger.debug("Matter patch control failed for \(deviceId}, falling back to Hue Bridge: \(error.localizedDescription)")
            guard let hueClient else {
                throw MatterError.noLightServiceFound
            }
            let huePatch = LightStatePatch(
                on: patch.power,
                brightness: patch.brightness,
                ct: patch.colorTemperatureMireds,
                xy: (patch.colorX, patch.colorY)
            )
            try await hueClient.patchLightState(resourceId: deviceId, state: huePatch)
        }
    }
    
    /// Refresh state for a specific Matter device, with automatic fallback to Hue Bridge.
    func refreshDeviceState(_ deviceId: String) async throws {
        do {
            guard let controller = controller(for: deviceId) else {
                throw MatterError.accessoryNotReachable
            }
            try await controller.refreshState()
        } catch {
            logger.debug("Matter refresh failed for \(deviceId}, falling back to Hue Bridge: \(error.localizedDescription)")
            guard let hueClient else {
                throw MatterError.noLightServiceFound
            }
            _ = try await hueClient.fetchState()
        }
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
    func importAreaMetadata() async -> [MatterAreaMetadata] {
        var metadata: [MatterAreaMetadata] = []
        
        for router in borderRouters where router.isOnline {
            metadata.append(MatterAreaMetadata(
                areaId: router.id,
                areaName: router.name,
                childAreaIds: [],
                assignedLightIds: []
            ))
        }
        
        return metadata
    }
    
    /// Get area metadata for a specific light device from the Matter network.
    func areaForLight(_ lightId: String) -> MatterAreaMetadata? {
        borderRouters.first { router in
            router.areaMetadata?.assignedLightIds.contains(lightId) ?? false
        }?.areaMetadata
    }
    
    /// Pre-populate light group assignments from Matter area metadata.
    func prePopulateLightGroups() async -> [String: [String]] {
        var groups: [String: [String]] = [:]
        
        for router in borderRouters {
            if let area = router.areaMetadata {
                groups[area.areaName] = area.assignedLightIds
            }
        }
        
        return groups
    }
    
    // MARK: - Private Helpers
    
    /// Get or create a Matter light controller for a device.
    private func controller(for deviceId: String) -> (any MatterLightController)? {
        if let existing = controllers[deviceId] {
            return existing
        }
        return nil
    }
}

// MARK: - HMHomeManagerDelegate Conformance

extension MatterBridgeService: HMHomeManagerDelegate {
    
    func homeManagerDidUpdateHomes(_ manager: HMHomeManager) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let previousReachability = hasReachableDevices
            homes = manager.homes
            
            if previousReachability != hasReachableDevices {
                for light in state.lights {
                    onDeviceStateChanged?(light)
                    onReachabilityChanged?(light.id, light.isReachable)
                }
            }
        }
    }
    
    func homeManager(_ manager: HMHomeManager, didAdd homes: [HMHome]) {
        Task { @MainActor [weak self] in
            self?.homes = manager.homes
        }
    }
    
    func homeManager(_ manager: HMHomeManager, didRemove homes: [HMHome]) {
        Task { @MainActor [weak self] in
            self?.homes = manager.homes
        }
    }
    
    func homeManager(_ manager: HMHomeManager, didUpdateHomes homes: [HMHome]) {
        Task { @MainActor [weak self] in
            self?.homes = homes
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
