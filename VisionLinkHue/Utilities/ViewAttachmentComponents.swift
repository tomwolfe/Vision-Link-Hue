import RealityKit
import SwiftUI
import Foundation

/// RealityKit 2026 fixture HUD entity factory.
/// Creates a visible billboard entity with a semi-transparent quad
/// that always faces the camera for fixture tracking overlays.
@MainActor
final class FixtureHUDFactory {
    
    /// Create a HUD entity for a tracked fixture with a visible billboard quad.
    /// The entity uses a BillboardComponent to always face the camera and
    /// displays a semi-transparent rounded-rect quad at the fixture's position.
    ///
    /// - Parameters:
    ///   - fixture: The tracked fixture to create a HUD for.
    ///   - scene: The RealityKit scene to add the entity to.
    ///   - anchor: The parent anchor entity for the HUD.
    /// - Returns: The created entity, or nil if creation fails.
    func createHUD(for fixture: TrackedFixture, in scene: RealityKit.Scene, parent anchor: Entity) -> Entity? {
        let aspectRatio: Float = 2.0
        let width: Float = 0.08
        let height = width / aspectRatio
        
        let mesh = MeshResource.generateBox(
            size: SIMD3<Float>(width, height, 0.001),
            cornerRadius: 0.01
        )
        
        let material = MeshMaterial()
        material.color = .init(
            diffuse: .init(color: .systemBackground),
            roughness: .init(color: .init(color: .white))
        )
        material.opacity = .init(0.85, interpolation: .linear)
        
        let entity = ModelEntity(mesh: mesh, materials: [material])
        entity.name = "FixtureHUD-\(fixture.id.uuidString)"
        entity.position = fixture.position
        entity.orientation = fixture.orientation
        
        entity.components.set(BillboardComponent())
        
        anchor.addChild(entity)
        
        return entity
    }
}

/// SwiftUI view rendered as a RealityKit HUD overlay on a fixture entity.
struct FixtureHUDView: View {
    let fixture: TrackedFixture
    
    var body: some View {
        VStack(spacing: 4) {
            Text(fixture.type.displayName)
                .font(.caption2)
                .fontWeight(.semibold)
            
            Text(String(format: "%.1f m", fixture.distanceMeters))
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 4))
        .shadow(radius: 2)
    }
}
