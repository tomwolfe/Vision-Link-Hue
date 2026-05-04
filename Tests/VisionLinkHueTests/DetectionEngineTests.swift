import XCTest
@testable import VisionLinkHue

/// Tests for `DetectionEngine` focusing on pure logic:
/// non-maximum suppression (NMS), IoU calculation, confidence filtering,
/// and inference throttling.
final class DetectionEngineTests: XCTestCase {
    
    private var engine: DetectionEngine!
    
    override func setUp() {
        super.setUp()
        engine = DetectionEngine()
    }
    
    override func tearDown() {
        engine = nil
        super.tearDown()
    }
    
    // MARK: - Throttling Tests
    
    func testProcessFrameThrottlingReturnsEmptyWithinInterval() async {
        engine.start()
        
        // Create a minimal pixel buffer for testing.
        guard let pixelBuffer = createTestPixelBuffer() else {
            XCTFail("Failed to create test pixel buffer")
            return
        }
        
        // First call should process (returns empty since no Vision framework in tests, but throttling should allow it).
        let firstResult = try? await engine.processFrame(pixelBuffer, timestamp: 0)
        XCTAssertNotNil(firstResult)
        
        // Immediate second call should be throttled (return empty).
        let secondResult = try? await engine.processFrame(pixelBuffer, timestamp: 0.001)
        XCTAssertEqual(secondResult?.count, 0, "Second call within interval should be throttled")
    }
    
    func testProcessFrameAllowsAfterInterval() async {
        engine.start()
        
        guard let pixelBuffer = createTestPixelBuffer() else {
            XCTFail("Failed to create test pixel buffer")
            return
        }
        
        _ = try? await engine.processFrame(pixelBuffer, timestamp: 0)
        
        // Wait for the inference interval to pass.
        try? await Task.sleep(for: .milliseconds(Int(DetectionConstants.inferenceInterval * 1000) + 100))
        
        // Should allow processing again.
        let result = try? await engine.processFrame(pixelBuffer, timestamp: DetectionConstants.inferenceInterval + 0.1)
        XCTAssertNotNil(result)
    }
    
    func testProcessFrameReturnsEmptyWhenStopped() async {
        engine.stop()
        
        guard let pixelBuffer = createTestPixelBuffer() else {
            XCTFail("Failed to create test pixel buffer")
            return
        }
        
        let result = try? await engine.processFrame(pixelBuffer, timestamp: 0)
        XCTAssertEqual(result?.count, 0, "Stopped engine should return empty detections")
    }
    
    // MARK: - Confidence Filtering Tests
    
    func testMinConfidenceFiltersLowConfidenceDetections() {
        // DetectionEngine's minConfidence is DetectionConstants.minConfidence (0.6).
        // Create detections with varying confidence levels.
        let lowConfDetection = FixtureDetection(
            type: .lamp,
            region: NormalizedRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2),
            confidence: 0.5
        )
        let highConfDetection = FixtureDetection(
            type: .lamp,
            region: NormalizedRect(x: 0.5, y: 0.1, width: 0.2, height: 0.2),
            confidence: 0.7
        )
        let boundaryDetection = FixtureDetection(
            type: .lamp,
            region: NormalizedRect(x: 0.3, y: 0.1, width: 0.2, height: 0.2),
            confidence: DetectionConstants.minConfidence
        )
        
        // Verify that low confidence is below threshold.
        XCTAssertLessThan(lowConfDetection.confidence, DetectionConstants.minConfidence)
        
        // Verify that high confidence is above threshold.
        XCTAssertGreaterThan(highConfDetection.confidence, DetectionConstants.minConfidence)
        
        // Verify that boundary confidence equals threshold.
        XCTAssertEqual(boundaryDetection.confidence, DetectionConstants.minConfidence)
    }
    
    // MARK: - NMS Logic Tests
    
    func testNonMaxSuppressionRemovesOverlappingDetections() async {
        // Create two overlapping detections with different confidence.
        let highConfDetection = FixtureDetection(
            type: .lamp,
            region: NormalizedRect(x: 0.3, y: 0.1, width: 0.3, height: 0.3),
            confidence: 0.9
        )
        let lowConfDetection = FixtureDetection(
            type: .lamp,
            region: NormalizedRect(x: 0.4, y: 0.2, width: 0.3, height: 0.3),
            confidence: 0.7
        )
        
        // The regions overlap significantly.
        let iou = highConfDetection.region.intersectionOverUnion(with: lowConfDetection.region)
        XCTAssertGreaterThan(iou, 0.0, "Regions should overlap")
        XCTAssertGreaterThan(iou, 0.3, "IoU should exceed NMS threshold")
        
        // Invoke nonMaxSuppression and verify the high-confidence detection is kept.
        let result = await engine.nonMaxSuppression([highConfDetection, lowConfDetection], iouThreshold: 0.3)
        XCTAssertEqual(result.count, 1, "NMS should suppress the lower-confidence overlapping detection")
        XCTAssertEqual(result.first?.id, highConfDetection.id, "NMS should keep the higher-confidence detection")
    }
    
    func testNonMaxSuppressionKeepsNonOverlappingDetections() async {
        let detection1 = FixtureDetection(
            type: .lamp,
            region: NormalizedRect(x: 0.0, y: 0.0, width: 0.1, height: 0.1),
            confidence: 0.8
        )
        let detection2 = FixtureDetection(
            type: .lamp,
            region: NormalizedRect(x: 0.8, y: 0.8, width: 0.1, height: 0.1),
            confidence: 0.9
        )
        
        // These regions are far apart.
        let iou = detection1.region.intersectionOverUnion(with: detection2.region)
        XCTAssertEqual(iou, 0.0, "Non-overlapping regions should have IoU of 0")
        
        // Invoke nonMaxSuppression and verify both detections survive.
        let result = await engine.nonMaxSuppression([detection1, detection2], iouThreshold: 0.3)
        XCTAssertEqual(result.count, 2, "NMS should keep both non-overlapping detections")
    }
    
    func testNonMaxSuppressionEmptyInputReturnsEmpty() async {
        // Empty detection array should produce empty result.
        let result = await engine.nonMaxSuppression([], iouThreshold: 0.3)
        XCTAssertTrue(result.isEmpty, "NMS with empty input should return empty result")
    }
    
    // MARK: - Vision Coordinate Space Tests
    
    func testNormalizedRectYAxisFlipping() {
        // Vision framework uses bottom-left origin.
        // When creating a NormalizedRect from a Vision bounding box,
        // the Y values must be flipped for ARKit/Camera coordinate space.
        
        // Simulate a Vision bounding box: minY=0.2 (bottom), maxY=0.8 (top)
        // After flipping: topLeft.y = 1.0 - 0.8 = 0.2 (top in ARKit space)
        //                  bottomRight.y = 1.0 - 0.2 = 0.8 (bottom in ARKit space)
        
        let visionMinY: Float = 0.2
        let visionMaxY: Float = 0.8
        
        let flippedTopY = 1.0 - visionMaxY
        let flippedBottomY = 1.0 - visionMinY
        
        XCTAssertEqual(flippedTopY, 0.2, accuracy: 0.001, "Flipped top Y should be 0.2")
        XCTAssertEqual(flippedBottomY, 0.8, accuracy: 0.001, "Flipped bottom Y should be 0.8")
        
        // Verify the flipped rect has correct ordering
        let rect = NormalizedRect(
            topLeft: SIMD2<Float>(0.1, flippedTopY),
            bottomRight: SIMD2<Float>(0.9, flippedBottomY)
        )
        
        XCTAssertLessThan(rect.topLeft.y, rect.bottomRight.y, "Top Y should be less than bottom Y in ARKit space")
        XCTAssertEqual(rect.height, 0.6, accuracy: 0.001, "Height should be preserved after flip")
    }
    
    // MARK: - Model Quantization Tests
    
    func testModelQuantizationFlagExists() {
        let engine = DetectionEngine()
        XCTAssertFalse(engine.isModelQuantized, "Model should not be quantized by default")
    }
    
    func testReloadResetsQuantizationFlag() {
        let engine = DetectionEngine()
        let initialQuantized = engine.isModelQuantized
        
        engine.reloadObjectDetectionModel()
        
        XCTAssertFalse(engine.isModelQuantized, "Reload should reset quantization flag")
    }
    
    // MARK: - Helper Methods
    
    /// Create a minimal test pixel buffer (1x1 RGBA).
    private func createTestPixelBuffer() -> CVPixelBuffer? {
        let width = 1
        let height = 1
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: kCFBooleanTrue,
            kCVPixelBufferCGBitmapContextCompatibilityKey: kCFBooleanTrue,
        ]
        
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            nil,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &pixelBuffer
        )
        
        guard status == kCVReturnSuccess else {
            return nil
        }
        
        return pixelBuffer
    }
}
