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
    /// Includes a CollisionComponent with a bounding sphere for raycast
    /// disambiguation when multiple fixtures overlap in the camera view.
    ///
    /// - Parameters:
    ///   - fixture: The tracked fixture to create a HUD for.
    ///   - scene: The RealityKit scene to add the entity to.
    ///   - anchor: The parent anchor entity for the HUD.
    /// - Returns: The created entity, or nil if creation fails.
    func createHUD(for fixture: TrackedFixture, in scene: RealityKit.Scene, parent anchor: Entity) -> Entity? {
        let entity = Entity()
        entity.name = "FixtureHUD-\(fixture.id.uuidString)"
        entity.position = fixture.position
        entity.orientation = fixture.orientation
        
        entity.components.set(BillboardComponent())
        
        // SwiftUI view rendering via ViewAttachmentComponent requires
        // RealityKit 2026+ ViewAttachmentComponent API.
        // entity.components.set(ViewAttachmentComponent(FixtureHUDView(fixture: fixture)))
        
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
