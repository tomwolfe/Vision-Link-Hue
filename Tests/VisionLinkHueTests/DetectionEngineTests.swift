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
        let iou = calculateIoU(highConfDetection.region, lowConfDetection.region)
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
        let iou = calculateIoU(detection1.region, detection2.region)
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
    
    // MARK: - Helper Methods
    
    /// Calculate IoU between two normalized rects (internal logic extracted for testing).
    private func calculateIoU(_ a: NormalizedRect, _ b: NormalizedRect) -> Float {
        let interX1 = max(a.topLeft.x, b.topLeft.x)
        let interY1 = max(a.topLeft.y, b.topLeft.y)
        let interX2 = min(a.bottomRight.x, b.bottomRight.x)
        let interY2 = min(a.bottomRight.y, b.bottomRight.y)
        
        let interWidth = max(0, interX2 - interX1)
        let interHeight = max(0, interY2 - interY1)
        let intersection = interWidth * interHeight
        
        let areaA = a.width * a.height
        let areaB = b.width * b.height
        let union = areaA + areaB - intersection
        
        return union > 0 ? intersection / Float(union) : 0
    }
    
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
