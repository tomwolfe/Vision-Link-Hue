import Foundation
import simd
import RealityKit

/// Categories of lighting fixtures the on-device model can detect.
/// Includes architectural archetypes recognized by the CoreML object
/// detection model (Chandelier, Sconce, Desk Lamp) alongside traditional
/// geometric classification categories.
enum FixtureType: String, Codable, CaseIterable, Sendable {
    case lamp
    case recessed
    case pendant
    case ceiling
    case strip
    case chandelier
    case sconce
    case deskLamp
    
    var displayName: String {
        switch self {
        case .lamp: return "Table/Lamp"
        case .recessed: return "Recessed"
        case .pendant: return "Pendant"
        case .ceiling: return "Ceiling"
        case .strip: return "Strip Light"
        case .chandelier: return "Chandelier"
        case .sconce: return "Wall Sconce"
        case .deskLamp: return "Desk Lamp"
        }
    }
}

/// Normalized bounding rectangle in [0...1] range relative to camera frame.
struct NormalizedRect: Sendable {
    let topLeft: SIMD2<Float>
    let bottomRight: SIMD2<Float>
    
    init(topLeft: SIMD2<Float>, bottomRight: SIMD2<Float>) {
        self.topLeft = topLeft
        self.bottomRight = bottomRight
    }
    
    init(x: Float, y: Float, width: Float, height: Float) {
        self.topLeft = SIMD2<Float>(x, y)
        self.bottomRight = SIMD2<Float>(x + width, y + height)
    }
    
    /// Center point of the bounding box.
    var center: SIMD2<Float> {
        SIMD2<Float>(
            (topLeft.x + bottomRight.x) * 0.5,
            (topLeft.y + bottomRight.y) * 0.5
        )
    }
    
    /// Width of the bounding box.
    var width: Float { bottomRight.x - topLeft.x }
    
    /// Height of the bounding box.
    var height: Float { bottomRight.y - topLeft.y }
    
    /// Aspect ratio (width / height).
    var aspectRatio: Float { width / max(height, .ulpOfOne) }
    
    /// Convert to SwiftUI `Rect` for a given frame size.
    func toRect(in frameSize: CGSize) -> CGRect {
        CGRect(
            x: Double(topLeft.x) * frameSize.width,
            y: Double(topLeft.y) * frameSize.height,
            width: Double(width) * frameSize.width,
            height: Double(height) * frameSize.height
        )
    }
    
    /// Calculate the Intersection over Union (IoU) between this rect and another.
    func intersectionOverUnion(with other: NormalizedRect) -> Float {
        let interX1 = max(topLeft.x, other.topLeft.x)
        let interY1 = max(topLeft.y, other.topLeft.y)
        let interX2 = min(bottomRight.x, other.bottomRight.x)
        let interY2 = min(bottomRight.y, other.bottomRight.y)
        
        let interWidth = max(0, interX2 - interX1)
        let interHeight = max(0, interY2 - interY1)
        let intersection = interWidth * interHeight
        
        let areaA = width * height
        let areaB = other.width * other.height
        let union = areaA + areaB - intersection
        
        return union > 0 ? intersection / Float(union) : 0
    }
}

/// Result of an AI-driven fixture detection pass.
struct FixtureDetection: Identifiable, Sendable {
    let id: UUID
    let type: FixtureType
    let region: NormalizedRect
    let confidence: Double
    
    init(type: FixtureType, region: NormalizedRect, confidence: Double) {
        self.id = UUID()
        self.type = type
        self.region = region
        self.confidence = confidence
    }
}

/// A detected fixture with its resolved 3D world transform and HUD entity state.
/// Combines detection data, spatial position, and RealityKit entity tracking
/// into a single unified structure.
struct TrackedFixture: Identifiable, Sendable {
    let id: UUID
    let detection: FixtureDetection
    let position: SIMD3<Float>
    let orientation: simd_quatf
    let distanceMeters: Float
    let material: String?
    
    /// The RealityKit entity ID that represents this fixture's HUD.
    var hudEntityID: Entity.ID?
    
    /// The Philips Hue light ID (CLIP v2 UUID) that this fixture controls.
    /// Set via tap-to-link in the HUD or auto-matched by proximity to a
    /// known bridge light. This is distinct from `id`, which is a
    /// locally-generated UUID for the detection tracking.
    var mappedHueLightId: String?
    
    /// Manual depth offset applied to the fixture position (meters).
    /// Used on non-LiDAR devices where depth estimation falls back to
    /// a static distance. The user can adjust this via a HUD slider.
    var depthOffsetMeters: Float = 0.0
    
    /// Convenience accessor for fixture type.
    var type: FixtureType { detection.type }
    
    /// Convenience accessor for detection confidence.
    var confidence: Double { detection.confidence }
    
    /// Effective distance including manual depth offset.
    var effectiveDistanceMeters: Float {
        distanceMeters + depthOffsetMeters
    }
}
