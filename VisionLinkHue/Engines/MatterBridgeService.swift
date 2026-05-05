import Foundation
@preconcurrency import HomeKit
import os

/// Service that manages Matter/Thread-based smart lighting as a fallback
/// when the Philips Hue Bridge is unavailable. Provides device discovery,
/// state management, and control commands through the HomeKit framework.
///
/// NOTE: This is a work-in-progress stub. The discovery, state management,
/// and control methods are not yet implemented. They return empty results
/// or throw `.homeKitNotAvailable` / `.accessoryNotReachable` until the
/// Matter/Thread integration is complete per the roadmap.
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
    var isThreadNetworkAvailable: Bool { false }
    
    /// The current state of all Matter devices.
    /// NOTE: Stub — returns empty state. WIP: will populate from HomeKit accessories.
    var state: MatterBridgeState {
        MatterBridgeState(
            lights: [],
            borderRouters: [],
            threadNetworkAvailable: false,
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
    
    override init() {
        super.init()
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
        return await MainActor.run { controller.isReachable }
    }
    
    // MARK: - Device Control
    
    /// Turn a Matter light on or off.
    func toggle(deviceId: String, on: Bool) async throws {
        guard let controller = controller(for: deviceId) else {
            throw MatterError.accessoryNotReachable
        }
        try await controller.setPower(on)
    }
    
    /// Set the brightness of a Matter light.
    func setBrightness(_ brightness: Double, deviceId: String, transitionDuration: TimeInterval = 0.5) async throws {
        guard let controller = controller(for: deviceId) else {
            throw MatterError.accessoryNotReachable
        }
        try await controller.setBrightness(Int(brightness * 255), transitionDuration: Int(transitionDuration))
    }
    
    /// Set the color temperature of a Matter light.
    func setColorTemperature(_ temperature: Double, deviceId: String, transitionDuration: TimeInterval = 0.5) async throws {
        guard let controller = controller(for: deviceId) else {
            throw MatterError.accessoryNotReachable
        }
        try await controller.setColorTemperature(Int(temperature), transitionDuration: Int(transitionDuration))
    }
    
    /// Set the color of a Matter light using XY coordinates.
    func setColorX(_ x: Double, _ y: Double, deviceId: String, transitionDuration: TimeInterval = 0.5) async throws {
        guard let controller = controller(for: deviceId) else {
            throw MatterError.accessoryNotReachable
        }
        try await controller.setColorXY(x, y, transitionDuration: Int(transitionDuration))
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
    /// NOTE: Stub — returns empty array. WIP: parse Matter 1.5.1 Area Metadata.
    func importAreaMetadata() async -> [MatterAreaMetadata] {
        []
    }
    
    /// Get area metadata for a specific light device from the Matter network.
    /// NOTE: Stub — returns nil. WIP: resolve from Matter area hierarchy.
    func areaForLight(_ lightId: String) -> MatterAreaMetadata? {
        nil
    }
    
    /// Pre-populate light group assignments from Matter area metadata.
    /// NOTE: Stub — returns empty dictionary. WIP: map Matter areas to light groups.
    func prePopulateLightGroups() async -> [String: [String]] {
        [:]
    }
    
    // MARK: - Private Helpers
    
    /// NOTE: Stub — controllers are not yet populated. WIP: instantiate from HomeKit accessories.
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
