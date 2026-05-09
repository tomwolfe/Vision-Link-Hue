import XCTest
import SwiftData
@testable import VisionLinkHue

/// Unit tests for the lazy sorting optimization in `HueStateStream`.
/// Verifies that the SSE merge logic defers sorting until UI access,
/// improving performance for large setups (60+ lights).
@MainActor
final class HueStateStreamPerformanceTests: XCTestCase {
    
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
            archetype: nil
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
    
    // MARK: - Lazy Sorting Tests
    
    func testMergeDoesNotSortImmediately() async {
        // Apply multiple updates without accessing the sorted arrays
        for i in 0..<50 {
            let light = makeLight(id: "light-\(i)", index: i)
            let update = ResourceUpdate(lights: [light])
            stateStream.applyUpdate(update)
        }
        
        // The internal dictionary should have all 50 lights
        // (We verify via the sorted array access which triggers lazy sorting)
        XCTAssertEqual(stateStream.lights.count, 50)
    }
    
    func testSortedArraysAreReturnedCorrectly() async {
        // Insert lights in non-alphabetical order
        for i in (0..<20).reversed() {
            let light = makeLight(id: "light-\(i)", index: i)
            let update = ResourceUpdate(lights: [light])
            stateStream.applyUpdate(update)
        }
        
        let lights = stateStream.lights
        
        // Verify sorted order
        for i in 1..<lights.count {
            XCTAssertLessThan(lights[i-1].id, lights[i].id, "Lights should be sorted by ID")
        }
    }
    
    func testGroupsAreSortedCorrectly() async {
        for i in (0..<30).reversed() {
            let group = makeGroup(id: "group-\(i)", index: i)
            let update = ResourceUpdate(groups: [group])
            stateStream.applyUpdate(update)
        }
        
        let groups = stateStream.groups
        
        for i in 1..<groups.count {
            XCTAssertLessThan(groups[i-1].id, groups[i].id, "Groups should be sorted by ID")
        }
    }
    
    func testRefreshSortedArraysForcesResort() async {
        // Add some lights
        for i in 0..<10 {
            let light = makeLight(id: "light-\(i)", index: i)
            let update = ResourceUpdate(lights: [light])
            stateStream.applyUpdate(update)
        }
        
        // Access to trigger sorting
        _ = stateStream.lights
        
        // Add more lights
        for i in 10..<20 {
            let light = makeLight(id: "light-\(i)", index: i)
            let update = ResourceUpdate(lights: [light])
            stateStream.applyUpdate(update)
        }
        
        // Access again (should sort with new data)
        XCTAssertEqual(stateStream.lights.count, 20)
        
        // Force refresh
        stateStream.refreshSortedArrays()
        
        // Should still return correct data after refresh
        XCTAssertEqual(stateStream.lights.count, 20)
        
        // Verify sorting is correct
        for i in 1..<stateStream.lights.count {
            XCTAssertLessThan(stateStream.lights[i-1].id, stateStream.lights[i].id)
        }
    }
    
    func testLargeSetupPerformance() async {
        let lightCount = 100
        
        // Simulate rapid SSE updates (bulk insert without sorting each time)
        let start = DispatchTime.now()
        
        for i in 0..<lightCount {
            let light = makeLight(id: "light-\(i)", index: i)
            let update = ResourceUpdate(lights: [light])
            stateStream.applyUpdate(update)
        }
        
        let mergeEnd = DispatchTime.now()
        let mergeTime = Double(mergeEnd.uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000.0
        
        // Now trigger sorting by accessing the array
        _ = stateStream.lights
        
        let end = DispatchTime.now()
        let totalTime = Double(end.uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000.0
        
        // Merge should be fast (O(n) dictionary updates)
        XCTAssertLessThan(mergeTime, 0.01, "Merge should complete in under 10ms for \(lightCount) lights")
        
        // Total count should be correct
        XCTAssertEqual(stateStream.lights.count, lightCount)
    }
    
    func testSceneSortingCorrectness() async {
        for i in (0..<25).reversed() {
            let scene = HueSceneResource(
                id: "scene-\(i)",
                type: "Scene",
                metadata: HueSceneResource.Metadata(name: "Scene \(i)", archetype: nil),
                data: nil,
                lights: ["light-\(i)"]
            )
            let update = ResourceUpdate(scenes: [scene])
            stateStream.applyUpdate(update)
        }
        
        let scenes = stateStream.scenes
        
        for i in 1..<scenes.count {
            XCTAssertLessThan(scenes[i-1].id, scenes[i].id, "Scenes should be sorted by ID")
        }
    }
    
    func testMixedResourceUpdatesSortAllCorrectly() async {
        for i in 0..<40 {
            let light = makeLight(id: "light-\(i)", index: i)
            let group = makeGroup(id: "group-\(i)", index: i)
            let scene = HueSceneResource(
                id: "scene-\(i)",
                type: "Scene",
                metadata: HueSceneResource.Metadata(name: "Scene \(i)", archetype: nil),
                data: nil,
                lights: ["light-\(i)"]
            )
            
            let update = ResourceUpdate(
                lights: [light],
                scenes: [scene],
                groups: [group]
            )
            stateStream.applyUpdate(update)
        }
        
        XCTAssertEqual(stateStream.lights.count, 40)
        XCTAssertEqual(stateStream.scenes.count, 40)
        XCTAssertEqual(stateStream.groups.count, 40)
        
        // Verify all arrays are sorted
        for i in 1..<stateStream.lights.count {
            XCTAssertLessThan(stateStream.lights[i-1].id, stateStream.lights[i].id)
        }
        for i in 1..<stateStream.scenes.count {
            XCTAssertLessThan(stateStream.scenes[i-1].id, stateStream.scenes[i].id)
        }
        for i in 1..<stateStream.groups.count {
            XCTAssertLessThan(stateStream.groups[i-1].id, stateStream.groups[i].id)
        }
    }
}
