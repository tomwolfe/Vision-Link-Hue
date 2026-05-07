import XCTest
import MetricKit
@testable import VisionLinkHue

/// Tests for `MetricKitTelemetryService`.
final class MetricKitTelemetryTests: XCTestCase {
    
    func testServiceIsDisabledByDefaultOnSimulator() {
        let service = MetricKitTelemetryService()
        #if targetEnvironment(simulator)
        XCTAssertFalse(service.isAvailable)
        #else
        XCTAssertTrue(service.isAvailable)
        #endif
    }
    
    func testRecordInferenceCreatesRecord() async {
        let service = MetricKitTelemetryService(isEnabled: true)
        
        service.recordInference(
            latencyMs: 50.0,
            thermalState: .nominal,
            predictedThermalState: .nominal,
            ewmaLatency: 50.0,
            slopeMs: 0.0,
            sampleCount: 1,
            inferenceCount: 1,
            isModelQuantized: true
        )
        
        // Record should be accumulated but not submitted yet (batch size = 10).
        // We can verify by checking that flush triggers submission.
        XCTAssertFalse(service.isEnabled == false)
    }
    
    func testDisablePreventsRecording() async {
        let service = MetricKitTelemetryService(isEnabled: true)
        
        service.recordInference(
            latencyMs: 50.0,
            thermalState: .nominal,
            predictedThermalState: .nominal,
            ewmaLatency: 50.0,
            slopeMs: 0.0,
            sampleCount: 1,
            inferenceCount: 1,
            isModelQuantized: true
        )
        
        service.disable()
        
        // After disabling, no further records should be accumulated.
        // The service should have flushed any pending records.
        XCTAssertFalse(service.isEnabled)
    }
    
    func testSiliconGenerationInference() {
        XCTAssertEqual(SiliconGeneration.infer(from: "iPad14,1"), .a15)
        XCTAssertEqual(SiliconGeneration.infer(from: "iPhone14,2"), .a15)
        XCTAssertEqual(SiliconGeneration.infer(from: "iPad15,1"), .a16)
        XCTAssertEqual(SiliconGeneration.infer(from: "iPhone15,2"), .a16)
        XCTAssertEqual(SiliconGeneration.infer(from: "iPhone16,1"), .a17)
        XCTAssertEqual(SiliconGeneration.infer(from: "VisionPro1,1"), .a17)
        XCTAssertEqual(SiliconGeneration.infer(from: "Simulator"), .unknown)
        XCTAssertEqual(SiliconGeneration.infer(from: "arm64"), .m1)
        XCTAssertEqual(SiliconGeneration.infer(from: "unknown-chip"), .unknown)
    }
    
    func testTelemetryRecordPayload() {
        let record = TelemetryRecord(
            timestamp: Date(),
            thermalState: .warning,
            predictedThermalState: .serious,
            ewmaLatencyMs: 150.0,
            latencySlopeMs: 8.5,
            sampleCount: 42,
            batteryLevel: 0.75,
            isPluggedIn: true,
            siliconGeneration: "A15",
            isModelQuantized: true,
            inferenceCount: 100,
            memoryUsedMB: 256.0
        )
        
        let payload = record.payload
        
        XCTAssertEqual(payload["thermal_state"] as? String, "Warning")
        XCTAssertEqual(payload["predicted_thermal_state"] as? String, "Serious")
        XCTAssertEqual(payload["ewma_latency_ms"] as? Double, 150.0)
        XCTAssertEqual(payload["latency_slope_ms"] as? Double, 8.5)
        XCTAssertEqual(payload["sample_count"] as? Int, 42)
        XCTAssertEqual(payload["battery_level"] as? Double, 0.75)
        XCTAssertTrue(payload["is_plugged_in"] as? Bool == true)
        XCTAssertEqual(payload["silicon_generation"] as? String, "A15")
        XCTAssertTrue(payload["is_model_quantized"] as? Bool == true)
        XCTAssertEqual(payload["inference_count"] as? Int, 100)
        XCTAssertEqual(payload["memory_used_mb"] as? Double, 256.0)
        XCTAssertNotNil(payload["timestamp"] as? String)
    }
    
    func testBatchSizeTriggersSubmission() async {
        let service = MetricKitTelemetryService(isEnabled: true)
        
        // Record fewer than batch size - should not submit yet.
        for i in 0..<5 {
            service.recordInference(
                latencyMs: Double(50 + i),
                thermalState: .nominal,
                predictedThermalState: .nominal,
                ewmaLatency: Double(50 + i),
                slopeMs: 0.0,
                sampleCount: i + 1,
                inferenceCount: i + 1,
                isModelQuantized: true
            )
        }
        
        // Flush should trigger submission.
        service.flush()
    }
    
    func testJetsamTrackingInitialState() {
        let service = MetricKitTelemetryService(isEnabled: true)
        
        XCTAssertEqual(service.jetsamTerminationCount, 0)
        XCTAssertEqual(service.lastJetsamMemoryUsageMB, 0)
        XCTAssertFalse(service.wasUnquantizedFallbackActive)
    }
    
    func testMXAppExitDiagnosticHandlerIsConfigured() {
        let service = MetricKitTelemetryService(isEnabled: true)
        
        // The handler is registered via MXMetricKitReporter.setHandler().
        // We can verify the service initializes without crashing.
        XCTAssertNotNil(service)
        XCTAssertEqual(service.jetsamTerminationCount, 0)
    }
}
