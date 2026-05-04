import XCTest
import @testable VisionLinkHue

/// Unit tests for QuadrantCounts and QuadrantDensities, validating
/// the Swift 6.3 InlineArray-backed storage used in RelocalizationGuide.
final class QuadrantStorageTests: XCTestCase {
    
    // MARK: - QuadrantCounts Tests
    
    func testQuadrantCountsInitializesToZero() {
        let counts = QuadrantCounts()
        for quadrant in DepthQuadrant.allCases {
            XCTAssertEqual(counts[quadrant], 0, "Initial count should be zero for \(quadrant)")
        }
    }
    
    func testQuadrantCountsIncrement() {
        var counts = QuadrantCounts()
        counts[.topLeft] += 5
        counts[.topRight] += 3
        counts[.bottomLeft] += 7
        counts[.bottomRight] += 2
        
        XCTAssertEqual(counts[.topLeft], 5)
        XCTAssertEqual(counts[.topRight], 3)
        XCTAssertEqual(counts[.bottomLeft], 7)
        XCTAssertEqual(counts[.bottomRight], 2)
    }
    
    func testQuadrantCountsTotal() {
        var counts = QuadrantCounts()
        counts[.topLeft] = 10
        counts[.topRight] = 20
        counts[.bottomLeft] = 30
        counts[.bottomRight] = 40
        
        XCTAssertEqual(counts.total(), 100)
    }
    
    func testQuadrantCountsSparsest() {
        var counts = QuadrantCounts()
        counts[.topLeft] = 5
        counts[.topRight] = 10
        counts[.bottomLeft] = 2
        counts[.bottomRight] = 8
        
        XCTAssertEqual(counts.sparsest(), DepthQuadrant.bottomLeft.rawValue)
    }
    
    func testQuadrantCountsRichest() {
        var counts = QuadrantCounts()
        counts[.topLeft] = 5
        counts[.topRight] = 10
        counts[.bottomLeft] = 2
        counts[.bottomRight] = 8
        
        XCTAssertEqual(counts.richest(), DepthQuadrant.topRight.rawValue)
    }
    
    func testQuadrantCountsSpanIteration() {
        var counts = QuadrantCounts()
        counts[.topLeft] = 100
        counts[.topRight] = 200
        counts[.bottomLeft] = 300
        counts[.bottomRight] = 400
        
        let span = counts.asSpan()
        XCTAssertEqual(span.count, 4)
        
        var sum = 0
        for value in span {
            sum += value
        }
        XCTAssertEqual(sum, 1000)
    }
    
    // MARK: - QuadrantDensities Tests
    
    func testQuadrantDensitiesInitializesToZero() {
        let densities = QuadrantDensities()
        for quadrant in DepthQuadrant.allCases {
            XCTAssertEqual(densities[quadrant], 0.0, accuracy: 0.001, "Initial density should be zero for \(quadrant)")
        }
    }
    
    func testQuadrantDensitiesSetAndGet() {
        var densities = QuadrantDensities()
        densities[.topLeft] = 0.25
        densities[.topRight] = 0.50
        densities[.bottomLeft] = 0.15
        densities[.bottomRight] = 0.10
        
        XCTAssertEqual(densities[.topLeft], 0.25, accuracy: 0.001)
        XCTAssertEqual(densities[.topRight], 0.50, accuracy: 0.001)
        XCTAssertEqual(densities[.bottomLeft], 0.15, accuracy: 0.001)
        XCTAssertEqual(densities[.bottomRight], 0.10, accuracy: 0.001)
    }
    
    func testQuadrantDensitiesTotal() {
        var densities = QuadrantDensities()
        densities[.topLeft] = 0.1
        densities[.topRight] = 0.2
        densities[.bottomLeft] = 0.3
        densities[.bottomRight] = 0.4
        
        XCTAssertEqual(densities.total(), 1.0, accuracy: 0.001)
    }
    
    func testQuadrantDensitiesEntropyUniform() {
        var densities = QuadrantDensities()
        densities[.topLeft] = 0.25
        densities[.topRight] = 0.25
        densities[.bottomLeft] = 0.25
        densities[.bottomRight] = 0.25
        
        // Uniform distribution should have maximum entropy = log(4)
        let maxEntropy = Float(log(4.0))
        XCTAssertEqual(densities.entropy(), maxEntropy, accuracy: 0.001)
    }
    
    func testQuadrantDensitiesEntropyZero() {
        var densities = QuadrantDensities()
        densities[.topLeft] = 1.0
        densities[.topRight] = 0.0
        densities[.bottomLeft] = 0.0
        densities[.bottomRight] = 0.0
        
        // All density in one quadrant should have zero entropy
        XCTAssertEqual(densities.entropy(), 0.0, accuracy: 0.001)
    }
    
    func testQuadrantDensitiesEntropySkewed() {
        var densities = QuadrantDensities()
        densities[.topLeft] = 0.6
        densities[.topRight] = 0.2
        densities[.bottomLeft] = 0.1
        densities[.bottomRight] = 0.1
        
        let entropy = densities.entropy()
        let maxEntropy = Float(log(4.0))
        
        // Skewed distribution should have entropy between 0 and max
        XCTAssertGreaterThan(entropy, 0.0)
        XCTAssertLessThan(entropy, maxEntropy)
    }
    
    func testQuadrantDensitiesSparsestAndRichest() {
        var densities = QuadrantDensities()
        densities[.topLeft] = 0.4
        densities[.topRight] = 0.1
        densities[.bottomLeft] = 0.3
        densities[.bottomRight] = 0.2
        
        XCTAssertEqual(densities.sparsest(), DepthQuadrant.topRight.rawValue)
        XCTAssertEqual(densities.richest(), DepthQuadrant.topLeft.rawValue)
    }
    
    func testQuadrantDensitiesSpanIteration() {
        var densities = QuadrantDensities()
        densities[.topLeft] = 0.1
        densities[.topRight] = 0.2
        densities[.bottomLeft] = 0.3
        densities[.bottomRight] = 0.4
        
        let span = densities.asSpan()
        XCTAssertEqual(span.count, 4)
        
        var sum: Float = 0.0
        for density in span {
            sum += density
        }
        XCTAssertEqual(sum, 1.0, accuracy: 0.001)
    }
    
    // MARK: - Integration: QuadrantCounts to QuadrantDensities Conversion
    
    func testConversionFromCountsToDensities() {
        var counts = QuadrantCounts()
        counts[.topLeft] = 100
        counts[.topRight] = 200
        counts[.bottomLeft] = 300
        counts[.bottomRight] = 400
        
        let total = Float(counts.total())
        let samplesPerQuadrant = 1000.0
        
        var densities = QuadrantDensities()
        for quadrant in DepthQuadrant.allCases {
            densities[quadrant] = Float(counts[quadrant]) / samplesPerQuadrant
        }
        
        XCTAssertEqual(densities[.topLeft], 0.1, accuracy: 0.001)
        XCTAssertEqual(densities[.topRight], 0.2, accuracy: 0.001)
        XCTAssertEqual(densities[.bottomLeft], 0.3, accuracy: 0.001)
        XCTAssertEqual(densities[.bottomRight], 0.4, accuracy: 0.001)
    }
}
