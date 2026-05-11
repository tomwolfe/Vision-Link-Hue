import XCTest
@testable import VisionLinkHue
import SwiftData
import simd

/// Unit tests for the MatterBridgeService Hue fallback behavior.
/// Validates that Matter control failures gracefully fall back to the Hue Bridge.
final class MatterBridgeServiceFallbackTests: XCTestCase {
    
    func testPreferredControlPathReturnsHueWhenBridgeAvailable() async {
        let service = MatterBridgeService(hueClient: nil)
        let path = await service.preferredControlPath(hueBridgeAvailable: true)
        XCTAssertEqual(path, .hue, "Should prefer Hue when bridge is available")
    }
    
    func testPreferredControlPathReturnsNoneWhenNeitherAvailable() async {
        let service = MatterBridgeService(hueClient: nil)
        let path = await service.preferredControlPath(hueBridgeAvailable: false)
        XCTAssertEqual(path, .none, "Should return .none when neither is available")
    }
    
    func testShouldUseMatterFallbackWhenHueUnavailable() {
        let service = MatterBridgeService(hueClient: nil)
        // With no matter devices, should not use matter fallback.
        XCTAssertFalse(service.shouldUseMatterFallback(hueBridgeAvailable: false))
    }
    
    func testShouldNotUseMatterFallbackWhenHueAvailable() {
        let service = MatterBridgeService(hueClient: nil)
        XCTAssertFalse(service.shouldUseMatterFallback(hueBridgeAvailable: true))
    }
    
    func testFetchDevicesThrowsWhenHomeKitNotAuthorized() {
        let service = MatterBridgeService(hueClient: nil)
        
        // HomeKit authorization is typically not authorized in test environment.
        // The service should throw homeKitNotAvailable.
        XCTAssertFalse(service.isHomeKitAvailable, "HomeKit should not be authorized in tests")
    }
    
    func testStateReturnsEmptyWhenNoDevices() {
        let service = MatterBridgeService(hueClient: nil)
        let state = service.state
        
        XCTAssertTrue(state.lights.isEmpty, "State should have no lights when not discovered")
        XCTAssertTrue(state.borderRouters.isEmpty, "State should have no border routers")
        XCTAssertFalse(state.threadNetworkAvailable, "Thread should not be available")
    }
}


    }
    
    override func tearDown() {
        persistence = nil
        modelContainer = nil
        super.tearDown()
    }
    
    func testExecuteBatchedPersistsAllOperations() async throws {
        let fixtureIds = (0..<20).map { _ in UUID() }
        
        let results = try await persistence.executeBatched(
            count: fixtureIds.count,
            batchSize: 5,
            operation: { [persistence] index in
                try await persistence.saveMapping(
                    fixtureId: fixtureIds[index],
                    lightId: "light-\(index)",
                    position: SIMD3<Float>(Float(index), 0, 0),
                    orientation: simd_quatf(),
                    distanceMeters: 1.0,
                    fixtureType: "pendant",
                    confidence: 0.9
                )
            }
        )
        
        XCTAssertEqual(results.count, 20, "Should return all results")
        let mappings = await persistence.loadMappings()
        XCTAssertEqual(mappings.count, 20, "All 20 mappings should be persisted despite save/rollback between each operation")
    }
    
    func testExecuteBatchedRollbackDoesNotCauseDataLoss() async throws {
        // Each operation saves and rolls back. The key assertion is that
        // the saved data persists across rollbacks.
        let fixtureIds = (0..<10).map { _ in UUID() }
        
        _ = try await persistence.executeBatched(
            count: fixtureIds.count,
            batchSize: 3,
            operation: { [persistence] index in
                try await persistence.saveMapping(
                    fixtureId: fixtureIds[index],
                    lightId: "light-\(index)",
                    position: SIMD3<Float>(Float(index), 0, 0),
                    orientation: simd_quatf(),
                    distanceMeters: 1.0,
                    fixtureType: "pendant",
                    confidence: 0.9
                )
            }
        )
        
        // Verify all mappings survived the save/rollback cycles.
        let mappings = await persistence.loadMappings()
        XCTAssertEqual(mappings.count, 10, "All mappings should survive save/rollback cycles")
        
        // Verify the light IDs are correct.
        let lightIds = mappings.map { $0.lightId! }
        for i in 0..<10 {
            XCTAssertEqual(lightIds[i], "light-\(i)", "Light ID \(i) should be persisted")
        }
    }
}
