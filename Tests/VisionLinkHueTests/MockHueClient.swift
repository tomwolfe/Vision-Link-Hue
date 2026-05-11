import Foundation
import simd
@testable import VisionLinkHue

/// Mock implementation of `HueClientProtocol` for unit testing.
/// All methods return immediately with no side effects.
final class MockHueClient: HueClientProtocol {
    
    var bridgeIP: String?
    var bridgePort: Int = 80
    var apiKey: String?
    
    /// Mock spatial service.
    let spatialService: HueSpatialService
    
    var didDiscoverBridges: [BridgeInfo] = []
    var didFetchState: Bool = false
    var didCreateApiKey: Bool = false
    var didStartEventStream: Bool = false
    var didDisconnect: Bool = false
    var didReconnect: Bool = false
    
    private(set) var patchCalls: [(resourceId: String, state: LightStatePatch)] = []
    private(set) var recallCalls: [(groupId: String, sceneId: String)] = []
    private(set) var toggleCalls: [(resourceId: String, on: Bool)] = []
    private(set) var brightnessCalls: [(resourceId: String, brightness: Int)] = []
    private(set) var colorTempCalls: [(resourceId: String, mireds: Int)] = []
    private(set) var colorXycalls: [(resourceId: String, x: Double, y: Double)] = []

    
    init() {
        self.spatialService = HueSpatialService(stateStream: nil)
    }
    
    func discoverBridges() async -> [BridgeInfo] {
        didDiscoverBridges = []
        return []
    }
    
    func createApiKey() async throws -> String {
        didCreateApiKey = true
        apiKey = "mock-key"
        return "mock-key"
    }
    
    func fetchState() async throws -> HueBridgeState {
        didFetchState = true
        return HueBridgeState(lights: [], scenes: [], groups: [], resources: nil)
    }
    
    func patchLightState(resourceId: String, state: LightStatePatch) async throws {
        patchCalls.append((resourceId: resourceId, state: state))
    }
    
    func recallScene(groupId: String, sceneId: String) async throws {
        recallCalls.append((groupId: groupId, sceneId: sceneId))
    }
    
    func setBrightness(resourceId: String, brightness: Int, transitionDuration: Int) async throws {
        brightnessCalls.append((resourceId: resourceId, brightness: brightness))
    }
    
    func setColorTemperature(resourceId: String, mireds: Int, transitionDuration: Int) async throws {
        colorTempCalls.append((resourceId: resourceId, mireds: mireds))
    }
    
    func setColorXY(resourceId: String, x: Double, y: Double, transitionDuration: Int) async throws {
        colorXycalls.append((resourceId: resourceId, x: x, y: y))
    }
    
    func togglePower(resourceId: String, on: Bool) async throws {
        toggleCalls.append((resourceId: resourceId, on: on))
    }
    
    func togglePower(groupId: String, on: Bool) async throws {
        toggleCalls.append((resourceId: groupId, on: on))
    }
    
    func setBrightness(groupId: String, brightness: Int, transitionDuration: Int) async throws {
        brightnessCalls.append((resourceId: groupId, brightness: brightness))
    }
    
    func setColorTemperature(groupId: String, mireds: Int, transitionDuration: Int) async throws {
        colorTempCalls.append((resourceId: groupId, mireds: mireds))
    }
    
    func setColorXY(groupId: String, x: Double, y: Double, transitionDuration: Int) async throws {
        colorXycalls.append((resourceId: groupId, x: x, y: y))
    }
    
    func verifySpatialAwareCompatibility() async throws -> BridgeSpatialInfo {
        return BridgeSpatialInfo(
            firmwareVersion: "1.976",
            supportsSpatialAware: true,
            supportsRoomMapping: true,
            supportedMaterialLabels: ["Glass", "Metal", "Wood"]
        )
    }
    
    func mapARKitToBridgeSpace(arKitPosition: SIMD3<Float>, arKitOrientation: simd_quatf, referencePoint: SIMD3<Float>?) -> (position: SpatialAwarePosition.Position3D, roomOffset: SpatialAwarePosition.RoomOffset?) {
        let origin = referencePoint ?? SIMD3<Float>(0, 0, 0)
        let roomOffset = SIMD3<Float>(
            arKitPosition.x - origin.x,
            arKitPosition.y - origin.y,
            arKitPosition.z - origin.z
        )
        return (
            SpatialAwarePosition.Position3D(simd: arKitPosition),
            SpatialAwarePosition.RoomOffset(simd: roomOffset)
        )
    }
    
    func createSpatialAwarePosition(context: DetectionContext) -> SpatialAwarePosition {
        let (position, roomOffset) = mapARKitToBridgeSpace(
            arKitPosition: context.arKitPosition,
            arKitOrientation: context.arKitOrientation,
            referencePoint: context.origin
        )
        return SpatialAwarePosition(
            id: context.lightId,
            position: position,
            confidence: context.confidence,
            fixtureType: context.fixtureType,
            roomId: context.roomId,
            areaId: context.areaId,
            timestamp: Date(),
            orientation: SpatialAwarePosition.Orientation(simd: context.arKitOrientation),
            materialLabel: context.materialLabel,
            roomOffset: roomOffset
        )
    }
    
    var isCalibrated: Bool {
        spatialService.isCalibrated
    }
    
    var isSpatialAwareSupported: Bool {
        spatialService.isSpatialAwareSupported
    }
    
    func startEventStream() {
        didStartEventStream = true
    }
    
    func disconnect() {
        didDisconnect = true
    }
    
    func reconnect() async {
        didReconnect = true
    }
    
    // MARK: - Matter Fallback
    
    var isMatterFallbackAvailable: Bool { false }
    var preferredControlPath: ControlPath {
        get async { .hue }
    }
    
    func fetchMatterDevices() async throws -> MatterBridgeState {
        return MatterBridgeState(lights: [])
    }
    
    func setMatterPower(deviceId: String, on: Bool) async throws {}
    func setMatterBrightness(deviceId: String, brightness: Int, transitionDuration: Int) async throws {}
    func setMatterColorTemperature(deviceId: String, mireds: Int, transitionDuration: Int) async throws {}
    func setMatterColorXY(deviceId: String, x: Double, y: Double, transitionDuration: Int) async throws {}
    func patchMatterLight(deviceId: String, patch: MatterLightStatePatch) async throws {}
}
