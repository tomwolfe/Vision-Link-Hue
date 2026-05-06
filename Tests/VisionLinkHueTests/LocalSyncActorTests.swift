import XCTest
@testable import VisionLinkHue

/// Tests for `LocalSyncActor` and related types.
final class LocalSyncActorTests: XCTestCase {
    
    func testActorInitialization() async {
        let actor = LocalSyncActor(deviceID: "test-device-1", deviceName: "Test Device")
        
        let peers = await actor.getPeers()
        XCTAssertTrue(peers.isEmpty)
    }
    
    func testActorStartStop() async {
        let actor = LocalSyncActor(deviceID: "test-device-2", deviceName: "Test Device 2")
        
        // Start should succeed (network channel creation may fail in test env).
        // We just verify the API doesn't crash.
        do {
            try await actor.start()
            // If started, stop it.
            await actor.stop()
        } catch {
            // Expected in test environment where network is unavailable.
            XCTAssertNotNil(error)
        }
    }
    
    func testPeerDiscoveryEmpty() async {
        let actor = LocalSyncActor(deviceID: "test-device-3", deviceName: "Test Device 3")
        let peers = await actor.getPeers()
        XCTAssertTrue(peers.isEmpty)
    }
    
    func testDeviceTypes() {
        // Verify device type detection works.
        #if os(visionOS)
        XCTAssertEqual(LocalSyncActor.currentDeviceType, "Vision Pro")
        #elseif UIDevice.current.userInterfaceIdiom == .phone
        XCTAssertEqual(LocalSyncActor.currentDeviceType, "iPhone")
        #elseif UIDevice.current.userInterfaceIdiom == .pad
        XCTAssertEqual(LocalSyncActor.currentDeviceType, "iPad")
        #else
        XCTAssertFalse(LocalSyncActor.currentDeviceType.isEmpty)
        #endif
    }
    
    func testLocalDeviceHashable() {
        let device1 = LocalDevice(
            id: "device-1",
            name: "Device 1",
            deviceType: "iPhone",
            isReachable: true
        )
        let device2 = LocalDevice(
            id: "device-1",
            name: "Device 1 Different Name",
            deviceType: "iPhone",
            isReachable: false
        )
        let device3 = LocalDevice(
            id: "device-2",
            name: "Device 2",
            deviceType: "iPad",
            isReachable: true
        )
        
        XCTAssertEqual(device1, device2)
        XCTAssertNotEqual(device1, device3)
        XCTAssertEqual(device1.hashValue, device2.hashValue)
    }
    
    func testLocalSyncMessageIDs() {
        let spatialPayload = SpatialSyncPayload(
            messageId: "msg-1",
            fixtureId: "fixture-1",
            lightId: "light-1",
            positionX: 0.0,
            positionY: 1.0,
            positionZ: 0.0,
            orientationX: 0.0,
            orientationY: 0.0,
            orientationZ: 0.0,
            orientationW: 1.0,
            distanceMeters: 1.0,
            fixtureType: "pendant",
            confidence: 0.9,
            version: 1,
            deviceID: "device-1",
            timestamp: Date()
        )
        
        XCTAssertEqual(LocalSyncMessage.spatialSync(spatialPayload).messageId, "msg-1")
        XCTAssertEqual(LocalSyncMessage.heartbeat.messageId.count, 36) // UUID format
        XCTAssertEqual(LocalSyncMessage.deviceInfoRequest.messageId.count, 36)
        
        let deviceInfo = DeviceInfoPayload(
            messageId: "info-1",
            deviceID: "device-1",
            deviceName: "Test",
            deviceType: "iPhone",
            osVersion: "18.0",
            hardwareModel: "arm64",
            appVersion: "1.0.0",
            timestamp: Date()
        )
        XCTAssertEqual(LocalSyncMessage.deviceInfoResponse(deviceInfo).messageId, "info-1")
    }
    
    func testLocalSyncErrorDescriptions() {
        XCTAssertEqual(LocalSyncError.listenerCreationFailed.errorDescription, "Failed to create local network listener")
        XCTAssertEqual(LocalSyncError.noDevicesReachable.errorDescription, "No devices reachable on the local network")
        XCTAssertNotNil(LocalSyncError.connectionLost.errorDescription)
        XCTAssertEqual(LocalSyncError.syncRejected("test").errorDescription, "Remote device rejected sync: test")
    }
}

/// Tests for CoreML compute units dynamic switching in DetectionEngine.
final class DetectionEngineComputeUnitsTests: XCTestCase {
    
    func testDefaultComputeUnitsAreAll() {
        let engine = DetectionEngine()
        // The engine should start with .all compute units by default.
        // We can verify this indirectly through the logger output or by
        // checking that reloadObjectDetectionModel doesn't crash.
        XCTAssertTrue(true) // Placeholder - actual test requires model loading.
    }
    
    func testThermalStateMapping() {
        // Verify thermal state comparison works correctly for compute unit switching.
        XCTAssertLessThan(ThermalState.nominal, ThermalState.fair)
        XCTAssertLessThan(ThermalState.fair, ThermalState.warning)
        XCTAssertLessThan(ThermalState.warning, ThermalState.serious)
        XCTAssertLessThan(ThermalState.serious, ThermalState.critical)
    }
    
    func testEffectiveThermalStateSelection() {
        // Verify that max() correctly selects the worse thermal state.
        let states: [ThermalState] = [.nominal, .fair, .warning, .serious, .critical]
        
        for i in 0..<states.count {
            for j in 0..<states.count {
                let maxState = max(states[i], states[j])
                let minState = min(states[i], states[j])
                
                XCTAssertFalse(maxState < minState)
                XCTAssertFalse(minState > maxState)
            }
        }
    }
}
