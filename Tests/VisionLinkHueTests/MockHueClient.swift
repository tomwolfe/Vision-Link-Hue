import Foundation

/// Mock implementation of `HueClientProtocol` for unit testing.
/// All methods return immediately with no side effects.
final class MockHueClient: HueClientProtocol {
    
    var bridgeIP: String?
    var bridgePort: Int = 80
    var apiKey: String?
    var lastError: String?
    
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
    
    func discoverBridges() async -> [BridgeInfo] {
        didDiscoverBridges = true
        return []
    }
    
    func createApiKey() async throws -> String {
        didCreateApiKey = true
        apiKey = "mock-key"
        return "mock-key"
    }
    
    func fetchState() async throws -> HueBridgeState {
        didFetchState = true
        return HueBridgeState(lights: [], scenes: [], groups: [], sensors: [])
    }
    
    func patchLightState(resourceId: String, state: LightStatePatch) async throws {
        patchCalls.append((resourceId: resourceId, state: state))
    }
    
    func recallScene(groupId: String, sceneId: String) async throws {
        recallCalls.append((groupId: groupId, sceneId: sceneId))
    }
    
    func setBrightness(resourceId: String, brightness: Int, transitionDuration: Int = 4) async throws {
        brightnessCalls.append((resourceId: resourceId, brightness: brightness))
    }
    
    func setColorTemperature(resourceId: String, mireds: Int, transitionDuration: Int = 4) async throws {
        colorTempCalls.append((resourceId: resourceId, mireds: mireds))
    }
    
    func setColorXY(resourceId: String, x: Double, y: Double, transitionDuration: Int = 4) async throws {
        colorXycalls.append((resourceId: resourceId, x: x, y: y))
    }
    
    func togglePower(resourceId: String, on: Bool) async throws {
        toggleCalls.append((resourceId: resourceId, on: on))
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
}
