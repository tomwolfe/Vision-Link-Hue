import Foundation
import SwiftData
import simd

/// SwiftData model for persisting fixture-to-light mappings with
/// spatial coordinates. Ensures atomic integrity for spatial
/// coordinate persistence and light ID associations.
@Model
@MainActor
final class FixtureMapping {
    /// Local UUID for the detected fixture.
    var fixtureId: String
    
    /// Philips Hue light ID (CLIP v2 UUID) mapped to this fixture.
    var lightId: String?
    
    /// 3D position of the fixture in world space.
    var positionX: Float
    var positionY: Float
    var positionZ: Float
    
    /// Orientation quaternion components.
    var orientationX: Float
    var orientationY: Float
    var orientationZ: Float
    var orientationW: Float
    
    /// Distance to the fixture in meters.
    var distanceMeters: Float
    
    /// Fixture type string for display.
    var fixtureType: String
    
    /// Detection confidence (0.0-1.0).
    var confidence: Double
    
    /// Last updated timestamp.
    var updatedAt: Date
    
    /// Whether this mapping has been synced to the Hue Bridge via SpatialAware.
    var isSyncedToBridge: Bool
    
    init(
        fixtureId: UUID,
        lightId: String? = nil,
        position: SIMD3<Float>,
        orientation: simd_quatf,
        distanceMeters: Float,
        fixtureType: String,
        confidence: Double
    ) {
        self.fixtureId = fixtureId.uuidString
        self.lightId = lightId
        self.positionX = position.x
        self.positionY = position.y
        self.positionZ = position.z
        self.orientationX = orientation.x
        self.orientationY = orientation.y
        self.orientationZ = orientation.z
        self.orientationW = orientation.w
        self.distanceMeters = distanceMeters
        self.fixtureType = fixtureType
        self.confidence = confidence
        self.updatedAt = Date()
        self.isSyncedToBridge = false
    }
    
    /// Convenience accessor for the fixture UUID.
    var uuid: UUID { UUID(uuidString: fixtureId) ?? UUID() }
    
    /// Convenience accessor for the 3D position.
    var position: SIMD3<Float> {
        SIMD3<Float>(positionX, positionY, positionZ)
    }
    
    /// Convenience accessor for the orientation quaternion.
    var orientation: simd_quatf {
        simd_quatf(x: orientationX, y: orientationY, z: orientationZ, w: orientationW)
    }
}
