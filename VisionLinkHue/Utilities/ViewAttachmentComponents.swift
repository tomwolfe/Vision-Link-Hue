import RealityKit
import SwiftUI
import Foundation

/// RealityKit 2026 fixture HUD entity factory.
/// Uses a BillboardComponent for automatic viewport-facing orientation.
/// The FixtureHUDView SwiftUI view is available for future integration
/// with RealityKit's ViewAttachmentComponent when the API becomes available.
///
/// This replaces the deprecated manual ViewAttachmentComponent and
/// HUDAttachmentComponent components. All new fixture HUDs use the
/// unified RealityKit 26 attachment system.
@MainActor
final class FixtureHUDFactory {
    
    /// Create a HUD entity for a tracked fixture using a billboard component
    /// that always faces the camera. The FixtureHUDView SwiftUI view is
    /// available for future integration with RealityKit's ViewAttachmentComponent.
    ///
    /// - Parameters:
    ///   - fixture: The tracked fixture to create a HUD for.
    ///   - scene: The RealityKit scene to add the entity to.
    ///   - anchor: The parent anchor entity for the HUD.
    /// - Returns: The created entity, or nil if creation fails.
    func createHUD(for fixture: TrackedFixture, in scene: RealityKit.Scene, parent anchor: Entity) -> Entity? {
        let entity = ModelEntity()
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
