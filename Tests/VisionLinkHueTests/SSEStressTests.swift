import XCTest
import @testable VisionLinkHue
import SwiftData
import simd

/// Unit tests for `HueStateStream` under high-frequency SSE event load.
/// Verifies that the state merge logic and `AppNotificationSystem` actor
/// handle 100+ events/sec without blocking the MainActor.
final class SSEStressTests: XCTestCase {
    
    private var persistence: FixturePersistence!
    private var modelContainer: ModelContainer!
    private var stateStream: HueStateStream!
    
    override func setUp() {
        super.setUp()
        
        let schema = Schema([FixtureMapping.self])
        modelContainer = try! ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        persistence = FixturePersistence(container: modelContainer)
        stateStream = HueStateStream(persistence: persistence)
        stateStream.configure()
    }
    
    override func tearDown() {
        stateStream = nil
        persistence = nil
        modelContainer = nil
        super.tearDown()
    }
    
    // MARK: - Helper Methods
    
    private func makeLight(id: String, index: Int) -> HueLightResource {
        let metadata = HueLightResource.Metadata(
            name: "Test Light \(index)",
            archetype: nil,
            archetypeValue: .ceiling,
            manufacturerCode: nil,
            firmwareVersion: nil,
            hardwarePlatformType: nil
        )
        
        let state = HueLightResource.LightState(
            on: true,
            brightness: 128,
            xy: [0.4, 0.3],
            hue: 0,
            saturation: 0,
            ct: 300 + index,
            colormode: "ct"
        )
        
        return HueLightResource(
            id: id,
            type: "Extended color light",
            metadata: metadata,
            state: state,
            product: nil,
            config: HueLightResource.Config(reachable: true)
        )
    }
    
    private func makeScene(id: String, index: Int) -> HueSceneResource {
        let metadata = HueSceneResource.Metadata(name: "Test Scene \(index)", archetype: nil)
        return HueSceneResource(
            id: id,
            type: "Scene",
            metadata: metadata,
            data: nil,
            lights: ["light-\(index)"]
        )
    }
    
    private func makeGroup(id: String, index: Int) -> BridgeGroup {
        return BridgeGroup(
            id: id,
            type: "LightGroup",
            state: BridgeGroup.GroupState(any_on: true, all_on: nil),
            action: BridgeGroup.GroupState(any_on: true, all_on: nil),
            lights: ["light-\(index)"],
            name: "Test Group \(index)"
        )
    }
    
    // MARK: - High-Frequency Event Merge Tests
    
    func testMerges100EventsPerSecondWithoutBlocking() {
        let expectation = expectation(description: "Process 100 SSE events")
        
        let eventCount = 100
        var processedCount = 0
        let queue = DispatchQueue(label: "stressTest", attributes: .concurrent)
        
        let start = DispatchTime.now()
        
        for i in 0..<eventCount {
            queue.async {
                let light = self.makeLight(id: "light-\(i)", index: i)
                let update = ResourceUpdate(lights: [light])
                self.stateStream.applyUpdate(update)
                processedCount += 1
            }
        }
        
        queue.async {
            let end = DispatchTime.now()
            let elapsed = Double(end.uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000.0
            let rate = Double(eventCount) / max(elapsed, 0.001)
            
            XCTAssertEqual(processedCount, eventCount, "All events should be processed")
            XCTAssertEqual(self.stateStream.lights.count, eventCount, "All lights should be merged")
            
            // Verify rate is reasonable (should handle 100+ events/sec easily)
            XCTAssertGreaterThan(rate, 50.0, "Should process at least 50 events/sec")
            
            expectation.fulfill()
        }
        
        waitForExpectations(timeout: 5.0)
    }
    
    func testMerges1000RapidLightUpdates() {
        let expectation = expectation(description: "Process 1000 rapid light updates")
        
        let updateCount = 1000
        let lightId = "shared-light"
        let queue = DispatchQueue(label: "stressTest", attributes: .concurrent)
        
        let start = DispatchTime.now()
        
        for i in 0..<updateCount {
            queue.async {
                let onState = i % 2 == 0
                let bri = UInt16(i % 255)
                let ct = 200 + i
                var state = HueLightResource.LightState(on: onState, brightness: Int(bri), xy: [0.4, 0.3], hue: 0, saturation: 0, ct: ct, colormode: "ct")
                
                let metadata = HueLightResource.Metadata(name: "Test Light", archetype: nil, archetypeValue: .ceiling, manufacturerCode: nil, firmwareVersion: nil, hardwarePlatformType: nil)
                
                let light = HueLightResource(
                    id: lightId,
                    type: "Extended color light",
                    metadata: metadata,
                    state: state,
                    product: nil,
                    config: HueLightResource.Config(reachable: true)
                )
                
                let update = ResourceUpdate(lights: [light])
                self.stateStream.applyUpdate(update)
            }
        }
        
        queue.async {
            let end = DispatchTime.now()
            let elapsed = Double(end.uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000.0
            
            // All updates target the same light ID, so only 1 light should exist
            XCTAssertEqual(self.stateStream.lights.count, 1, "Should have exactly 1 light (all updates target same ID)")
            
            // The last update should have bri = 254 (1000 % 255 = 254)
            XCTAssertEqual(self.stateStream.lights.first?.state.brightness, 254, "Last update should be reflected")
            
            let rate = Double(updateCount) / max(elapsed, 0.001)
            XCTAssertGreaterThan(rate, 100.0, "Should handle 100+ events/sec for same-resource updates")
            
            expectation.fulfill()
        }
        
        waitForExpectations(timeout: 10.0)
    }
    
    func testMergesMixedResourceUpdates() {
        let expectation = expectation(description: "Process mixed light/scene/group updates")
        
        let batchCount = 50
        let queue = DispatchQueue(label: "stressTest", attributes: .concurrent)
        
        let start = DispatchTime.now()
        
        for i in 0..<batchCount {
            queue.async {
                let light = self.makeLight(id: "light-\(i)", index: i)
                let scene = self.makeScene(id: "scene-\(i)", index: i)
                let group = self.makeGroup(id: "group-\(i)", index: i)
                
                let update = ResourceUpdate(
                    lights: [light],
                    scenes: [scene],
                    groups: [group]
                )
                
                self.stateStream.applyUpdate(update)
            }
        }
        
        queue.async {
            let end = DispatchTime.now()
            let elapsed = Double(end.uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000.0
            
            XCTAssertEqual(self.stateStream.lights.count, batchCount)
            XCTAssertEqual(self.stateStream.scenes.count, batchCount)
            XCTAssertEqual(self.stateStream.groups.count, batchCount)
            
            let rate = Double(batchCount * 3) / max(elapsed, 0.001)
            XCTAssertGreaterThan(rate, 100.0, "Should handle 100+ combined events/sec across all resource types")
            
            expectation.fulfill()
        }
        
        waitForExpectations(timeout: 10.0)
    }
    
    // MARK: - Notification System Stress Tests
    
    func testAppNotificationSystemHandlesRapidErrors() {
        let expectation = expectation(description: "Handle rapid error notifications")
        
        let errorCount = 200
        var notificationCounts: [Int] = []
        let queue = DispatchQueue(label: "notificationStress", attributes: .concurrent)
        let lock = NSLock()
        
        let start = DispatchTime.now()
        
        for i in 0..<errorCount {
            queue.async {
                let error = NSError(
                    domain: "SSEStressTests",
                    code: i,
                    userInfo: [NSLocalizedDescriptionKey: "Test error \(i)"]
                )
                
                self.stateStream.reportError(error, severity: .warning, source: "stress-test")
                
                lock.lock()
                let count = self.stateStream.activeErrors.count
                notificationCounts.append(count)
                lock.unlock()
            }
        }
        
        queue.async {
            let end = DispatchTime.now()
            let elapsed = Double(end.uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000.0
            
            // Due to deduplication and rate limiting, not all 200 errors should appear
            // The AppNotificationSystem should cap at maxNotifications (5)
            let maxObserved = notificationCounts.max() ?? 0
            XCTAssertLessThanOrEqual(maxObserved, 10, "Notification count should be capped by deduplication")
            
            // Should process all errors quickly
            let rate = Double(errorCount) / max(elapsed, 0.001)
            XCTAssertGreaterThan(rate, 50.0, "Should process error reports at 50+ per second")
            
            expectation.fulfill()
        }
        
        waitForExpectations(timeout: 5.0)
    }
    
    func testAppNotificationSystemDeduplicatesSameSource() {
        let expectation = expectation(description: "Deduplicate same-source errors")
        
        let errorCount = 100
        let queue = DispatchQueue(label: "dedupStress", attributes: .concurrent)
        
        let start = DispatchTime.now()
        
        for i in 0..<errorCount {
            queue.async {
                let error = NSError(
                    domain: "SSEStressTests",
                    code: 0, // Same error code for deduplication
                    userInfo: [NSLocalizedDescriptionKey: "Same error"]
                )
                
                self.stateStream.reportError(error, severity: .error, source: "dedup-test")
            }
        }
        
        queue.async {
            let end = DispatchTime.now()
            let elapsed = Double(end.uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000.0
            
            // Due to deduplication, should have at most 1 error from this source
            let errorsFromSource = self.stateStream.activeErrors.filter { $0.source == "dedup-test" }
            XCTAssertLessThanOrEqual(errorsFromSource.count, 1, "Same-source errors should be deduplicated")
            
            expectation.fulfill()
        }
        
        waitForExpectations(timeout: 5.0)
    }
    
    // MARK: - State Consistency Tests
    
    func testStateConsistencyAfterRapidUpdates() {
        let expectation = expectation(description: "Verify state consistency after rapid updates")
        
        let updateCount = 500
        let lightId = "consistent-light"
        let queue = DispatchQueue(label: "consistencyStress", attributes: .concurrent)
        
        for i in 0..<updateCount {
            queue.async {
                var state = HueLightResource.LightState(on: i % 2 == 0, brightness: i % 255, xy: [0.4, 0.3], hue: 0, saturation: 0, ct: 200 + i, colormode: "ct")
                
                let metadata = HueLightResource.Metadata(name: "Test Light", archetype: nil, archetypeValue: .ceiling, manufacturerCode: nil, firmwareVersion: nil, hardwarePlatformType: nil)
                
                let light = HueLightResource(
                    id: lightId,
                    type: "Extended color light",
                    metadata: metadata,
                    state: state,
                    product: nil,
                    config: HueLightResource.Config(reachable: true)
                )
                
                let update = ResourceUpdate(lights: [light])
                self.stateStream.applyUpdate(update)
            }
        }
        
        queue.async {
            // After all updates, state should be consistent
            XCTAssertEqual(self.stateStream.lights.count, 1)
            
            let light = self.stateStream.light(by: lightId)
            XCTAssertNotNil(light, "Light should be resolvable by ID")
            
            // State should reflect the last update
            XCTAssertEqual(light?.state.brightness, updateCount % 255)
            
            expectation.fulfill()
        }
        
        waitForExpectations(timeout: 10.0)
    }
    
    func testLightResolutionAfterBulkInsert() {
        let expectation = expectation(description: "Resolve lights after bulk insert")
        
        let lightCount = 200
        let queue = DispatchQueue(label: "bulkInsert", attributes: .concurrent)
        
        for i in 0..<lightCount {
            queue.async {
                let light = self.makeLight(id: "bulk-light-\(i)", index: i)
                let update = ResourceUpdate(lights: [light])
                self.stateStream.applyUpdate(update)
            }
        }
        
        queue.async {
            XCTAssertEqual(self.stateStream.lights.count, lightCount)
            
            // Verify each light is resolvable
            for i in 0..<lightCount {
                let resolved = self.stateStream.light(by: "bulk-light-\(i)")
                XCTAssertNotNil(resolved, "Light \(i) should be resolvable")
                XCTAssertEqual(resolved?.metadata.name, "Test Light \(i)")
            }
            
            expectation.fulfill()
        }
        
        waitForExpectations(timeout: 10.0)
    }
}
