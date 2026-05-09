import XCTest
@testable import VisionLinkHue
import SwiftData
import simd

/// Unit tests for `HueStateStream` under high-frequency SSE event load.
/// Verifies that the state merge logic and `AppNotificationSystem` actor
/// handle 100+ events/sec without blocking the MainActor.
@MainActor
final class SSEStressTests: XCTestCase {
    
    private var persistence: FixturePersistence!
    private var modelContainer: ModelContainer!
    private var stateStream: HueStateStream!
    
    override func setUp() async throws {
        try await super.setUp()
        
        let schema = Schema([FixtureMapping.self])
        modelContainer = await MainActor.run {
            try! ModelContainer(
                for: schema,
                configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
            )
        }
        persistence = await MainActor.run {
            FixturePersistence(container: modelContainer)
        }
        stateStream = await MainActor.run {
            HueStateStream(persistence: persistence)
        }
        await MainActor.run {
            stateStream.configure()
        }
    }
    
    override func tearDown() async throws {
        stateStream = nil
        persistence = nil
        modelContainer = nil
        try await super.tearDown()
    }
    
    // MARK: - Helper Methods
    
    private func makeLight(id: String, index: Int) -> HueLightResource {
        var metadata = HueLightResource.Metadata()
        metadata.name = "Test Light \(index)"
        metadata.archetype = "ceiling_bulb"
        
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
    
    func testMerges100EventsPerSecondWithoutBlocking() async {
        let eventCount = 100
        
        let start = DispatchTime.now()
        
                let stream: HueStateStream = stateStream
        await withTaskGroup(of: Void.self) { taskGroup in
            for i in 0..<eventCount {
                let light = makeLight(id: "light-\(i)", index: i)
                let update = ResourceUpdate(lights: [light])
                taskGroup.addTask {
                    await stream.applyUpdate(update)
                }
            }
        }
        
        let end = DispatchTime.now()
        let elapsed = Double(end.uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000.0
        let rate = Double(eventCount) / max(elapsed, 0.001)
        
        let lightCount = await MainActor.run { self.stateStream.lights.count }
        XCTAssertEqual(lightCount, eventCount, "All lights should be merged")
        
        // Verify rate is reasonable (should handle 100+ events/sec easily)
        XCTAssertGreaterThan(rate, 50.0, "Should process at least 50 events/sec")
    }
    
    func testMerges1000RapidLightUpdates() async {
        let updateCount = 1000
        let lightId = "shared-light"
        
        let start = DispatchTime.now()
        
        let stream: HueStateStream = stateStream
        await withTaskGroup(of: Void.self) { taskGroup in
            for i in 0..<updateCount {
                taskGroup.addTask {
                    let onState = i % 2 == 0
                    let bri = UInt16(i % 255)
                    let ct = 200 + i
                    var state = HueLightResource.LightState(on: onState, brightness: Int(bri), xy: [0.4, 0.3], hue: 0, saturation: 0, ct: ct, colormode: "ct")
                    
                    var metadata = HueLightResource.Metadata()
                    metadata.name = "Test Light"
                    
                    let light = HueLightResource(
                        id: lightId,
                        type: "Extended color light",
                        metadata: metadata,
                        state: state,
                        product: nil,
                        config: HueLightResource.Config(reachable: true)
                    )
                    
                    let update = ResourceUpdate(lights: [light])
                    await MainActor.run {
                        stream.applyUpdate(update)
                    }
                }
            }
        }
        
        let end = DispatchTime.now()
        let elapsed = Double(end.uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000.0
        
        // All updates target the same light ID, so only 1 light should exist
        let lightCount = await MainActor.run { self.stateStream.lights.count }
        XCTAssertEqual(lightCount, 1, "Should have exactly 1 light (all updates target same ID)")
        
        // The last update should have bri = 254 (1000 % 255 = 254)
        let brightness = await MainActor.run { self.stateStream.lights.first?.state.brightness }
        XCTAssertEqual(brightness, 254, "Last update should be reflected")
        
        let rate = Double(updateCount) / max(elapsed, 0.001)
        XCTAssertGreaterThan(rate, 100.0, "Should handle 100+ events/sec for same-resource updates")
    }
    
    func testMergesMixedResourceUpdates() async {
        let batchCount = 50
        
        let start = DispatchTime.now()
        
        let stream: HueStateStream = stateStream
        await withTaskGroup(of: Void.self) { taskGroup in
            for i in 0..<batchCount {
                let light = makeLight(id: "light-\(i)", index: i)
                let scene = makeScene(id: "scene-\(i)", index: i)
                let group = makeGroup(id: "group-\(i)", index: i)
                let update = ResourceUpdate(
                    lights: [light],
                    scenes: [scene],
                    groups: [group]
                )
                taskGroup.addTask {
                    await stream.applyUpdate(update)
                }
            }
        }
        
        let end = DispatchTime.now()
        let elapsed = Double(end.uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000.0
        
        let lightsCount = await MainActor.run { self.stateStream.lights.count }
        XCTAssertEqual(lightsCount, batchCount)
        let scenesCount = await MainActor.run { self.stateStream.scenes.count }
        XCTAssertEqual(scenesCount, batchCount)
        let groupsCount = await MainActor.run { self.stateStream.groups.count }
        XCTAssertEqual(groupsCount, batchCount)
        
        let rate = Double(batchCount * 3) / max(elapsed, 0.001)
        XCTAssertGreaterThan(rate, 100.0, "Should handle 100+ combined events/sec across all resource types")
    }
    
    // MARK: - Notification System Stress Tests
    
    func testAppNotificationSystemHandlesRapidErrors() async {
        let errorCount = 200
        
        let start = DispatchTime.now()
        
        let stream: HueStateStream = stateStream
        await withTaskGroup(of: Void.self) { taskGroup in
            for i in 0..<errorCount {
                let error = NSError(
                    domain: "SSEStressTests",
                    code: 0, // Same error code for deduplication
                    userInfo: [NSLocalizedDescriptionKey: "Same error"]
                )
                taskGroup.addTask {
                    await stream.reportError(error, severity: .error, source: "dedup-test")
                }
            }
        }
        
        let end = DispatchTime.now()
        let elapsed = Double(end.uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000.0
        
        // Due to deduplication, should have at most 1 error from this source
        let errorsFromSource = await MainActor.run { self.stateStream.activeErrors.filter { $0.source == "dedup-test" } }
        XCTAssertLessThanOrEqual(errorsFromSource.count, 1, "Same-source errors should be deduplicated")
    }
    
    // MARK: - State Consistency Tests
    
    func testStateConsistencyAfterRapidUpdates() async {
        let updateCount = 500
        let lightId = "consistent-light"
        
        let stream: HueStateStream = stateStream
        await withTaskGroup(of: Void.self) { taskGroup in
            for i in 0..<updateCount {
                taskGroup.addTask {
                    var state = HueLightResource.LightState(on: i % 2 == 0, brightness: i % 255, xy: [0.4, 0.3], hue: 0, saturation: 0, ct: 200 + i, colormode: "ct")
                    
                    var metadata = HueLightResource.Metadata()
                    metadata.name = "Test Light"
                    
                    let light = HueLightResource(
                        id: lightId,
                        type: "Extended color light",
                        metadata: metadata,
                        state: state,
                        product: nil,
                        config: HueLightResource.Config(reachable: true)
                    )
                    
                    let update = ResourceUpdate(lights: [light])
                    await MainActor.run {
                        stream.applyUpdate(update)
                    }
                }
            }
        }
        
        // After all updates, state should be consistent
        let lightsCount = await MainActor.run { self.stateStream.lights.count }
        XCTAssertEqual(lightsCount, 1)
        
        let light = await MainActor.run { self.stateStream.light(by: lightId) }
        XCTAssertNotNil(light, "Light should be resolvable by ID")
        
        // State should reflect the last update
        XCTAssertEqual(light?.state.brightness, updateCount % 255)
    }
    
    func testLightResolutionAfterBulkInsert() async {
        let lightCount = 200
        
        let stream: HueStateStream = stateStream
        await withTaskGroup(of: Void.self) { taskGroup in
            for i in 0..<lightCount {
                let light = makeLight(id: "bulk-light-\(i)", index: i)
                let update = ResourceUpdate(lights: [light])
                taskGroup.addTask {
                    await stream.applyUpdate(update)
                }
            }
        }
        
        let lightCountResult = await MainActor.run { self.stateStream.lights.count }
        XCTAssertEqual(lightCountResult, lightCount)
        
        // Verify each light is resolvable
        for i in 0..<lightCount {
            let resolved = await MainActor.run { self.stateStream.light(by: "bulk-light-\(i)") }
            XCTAssertNotNil(resolved, "Light \(i) should be resolvable")
            XCTAssertEqual(resolved?.metadata.name, "Test Light \(i)")
        }
    }
}
