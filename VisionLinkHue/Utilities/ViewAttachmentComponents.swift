import RealityKit
import SwiftUI
import Foundation

/// RealityKit 2026 fixture HUD entity factory.
/// Uses the native ViewAttachmentComponent(rootView:) API for automatic
/// SwiftUI view lifecycle management and @Observable-driven entity updates.
///
/// This replaces the deprecated manual ViewAttachmentComponent and
/// HUDAttachmentComponent components. All new fixture HUDs use the
/// unified RealityKit 26 attachment system.
@MainActor
final class FixtureHUDFactory {
    
    /// Create a HUD entity for a tracked fixture using the native
    /// RealityKit 26 ViewAttachmentComponent API.
    ///
    /// The native ViewAttachmentComponent(rootView:) handles view lifecycle
    /// automatically and drives SwiftUI updates through @Observable entity properties.
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
        
        let attachment = ViewAttachmentComponent(rootView: {
            FixtureHUDView(fixture: fixture)
        })
        
        entity.components.set(attachment)
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
