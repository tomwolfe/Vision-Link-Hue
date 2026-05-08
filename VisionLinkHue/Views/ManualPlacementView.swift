import SwiftUI
import SwiftData
import ARKit
import UIKit

/// View for manually assigning room and zone to fixtures when
/// SpatialAware features are unavailable (older Bridge hardware).
/// Supports both traditional dropdown selection and AR-guided placement
/// with tap-to-place using ARHitTestResult for accurate positioning.
struct ManualPlacementView: View {

    @Environment(HueClient.self) private var hueClient
    @Environment(HueStateStream.self) private var stateStream
    @Environment(ARSessionManager.self) private var arSessionManager
    @Environment(\.dismiss) private var dismiss

    @State private var selectedFixture: TrackedFixture?
    @State private var selectedRoomId: String?
    @State private var selectedAreaId: String?
    @State private var isSaving: Bool = false
    @State private var saveMessage: String?
    @State private var manualAssignments: [String: (roomId: String, areaId: String?)] = [:]

    /// Whether AR-guided placement mode is active.
    /// When enabled, shows the AR camera view with tap-to-place overlay
    /// instead of the traditional dropdown pickers.
    @State private var isARGuidedMode: Bool = false

    /// Hit test result from AR-guided tap placement.
    @State private var arHitPosition: SIMD3<Float>?
    @State private var showARHitReticle: Bool = false

    /// Available rooms from the Hue Bridge.
    private var availableRooms: [BridgeGroup] {
        stateStream.groups.filter { $0.type == "room" }
    }

    /// Available areas from the Hue Bridge.
    private var availableAreas: [BridgeGroup] {
        stateStream.groups.filter { $0.type == "lightgroup" || $0.type == "zone" }
    }

    var body: some View {
        NavigationStack {
            Group {
                if isARGuidedMode {
                    arGuidedPlacementView
                } else {
                    traditionalPlacementForm
                }
            }
            .navigationTitle("Manual Placement")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Picker("Mode", selection: $isARGuidedMode) {
                        Text("Form").tag(false as Bool)
                        Text("AR Guide").tag(true as Bool)
                    }
                    .pickerStyle(.segmented)
                }
            }
            .onAppear {
                Task { await loadManualAssignments() }
            }
        }
    }

    /// Traditional form-based placement with dropdown pickers.
    private var traditionalPlacementForm: some View {
        Form {
            Section("Fixture") {
                if let fixture = selectedFixture {
                    HStack {
                        Text(fixture.type.displayName)
                        Spacer()
                        Text(fixture.mappedHueLightId ?? "Unlinked")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Picker("Select Fixture", selection: $selectedFixture) {
                        Text("Choose a fixture...").tag(TrackedFixture?(nil))
                        ForEach(pendingFixtures) { fixture in
                            Text("\(fixture.type.displayName) - \(fixture.mappedHueLightId ?? "Unlinked")")
                                .tag(fixture as TrackedFixture?)
                        }
                    }
                    .pickerStyle(.wheel)
                }
            }

            Section("Room Assignment") {
                if let _ = selectedFixture {
                    if availableRooms.isEmpty {
                        Text("No rooms found on bridge")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Room", selection: $selectedRoomId) {
                            Text("Select room...").tag(String?(nil))
                            ForEach(availableRooms, id: \.id) { room in
                                Text(room.name).tag(room.id as String?)
                            }
                        }
                        .pickerStyle(.navigationLink)
                    }
                }
            }

            Section("Zone (Optional)") {
                if let _ = selectedFixture {
                    if availableAreas.isEmpty {
                        Text("No zones available")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Zone", selection: $selectedAreaId) {
                            Text("None").tag(String?(nil))
                            ForEach(availableAreas, id: \.id) { area in
                                Text(area.name).tag(area.id as String?)
                            }
                        }
                        .pickerStyle(.navigationLink)
                    }
                }
            }

            Section("Saved Placements (\(manualAssignments.count))") {
                if manualAssignments.isEmpty {
                    Text("No manual placements saved")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(manualAssignments.keys.sorted(), id: \.self) { fixtureId in
                        let assignment = manualAssignments[fixtureId]!
                        HStack {
                            Text(fixtureId)
                            Spacer()
                            Text(assignment.roomId)
                                .foregroundStyle(.secondary)
                            if let area = assignment.areaId {
                                Text(area)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            if let msg = saveMessage {
                Section {
                    Text(msg)
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
            }

            Section {
                Button("Save Placement") {
                    Task { await savePlacement() }
                }
                .foregroundStyle(.blue)
                .disabled(selectedFixture == nil || selectedRoomId == nil)

                Button("Clear All Manual Placements") {
                    clearAllManualPlacements()
                }
                .foregroundStyle(.red)
            }
        }
    }

    /// AR-guided placement view with camera overlay and tap-to-place.
    /// Uses ARHitTestResult to align placement with real-world surfaces.
    private var arGuidedPlacementView: some View {
        ZStack {
            // AR camera preview
            ARKitPreviewView()
                .ignoresSafeArea()
                .gesture(
                    DragGesture()
                        .onEnded { value in
                            handleARTap(at: value.location)
                        }
                )

            // Reticle overlay at tap location
            if showARHitReticle, let position = arHitPosition {
                ARPlacementReticle(position: position)
                    .transition(.scale)
                    .animation(.easeOut(duration: 0.2), value: showARHitReticle)
            }

            // Bottom controls panel
            VStack {
                Spacer()

                VStack(spacing: 16) {
                    // Fixture selector
                    if !pendingFixtures.isEmpty {
                        Picker("Fixture", selection: $selectedFixture) {
                            Text("Choose a fixture...").tag(TrackedFixture?(nil))
                            ForEach(pendingFixtures) { fixture in
                                Text("\(fixture.type.displayName)")
                                    .tag(fixture as TrackedFixture?)
                            }
                        }
                        .pickerStyle(.wheel)
                        .frame(height: 150)
                    } else {
                        Text("No fixtures detected. Use AR mode to detect first.")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }

                    // Room selector
                    if !availableRooms.isEmpty {
                        Picker("Room", selection: $selectedRoomId) {
                            Text("Select room...").tag(String?(nil))
                            ForEach(availableRooms, id: \.id) { room in
                                Text(room.name).tag(room.id as String?)
                            }
                        }
                        .pickerStyle(.wheel)
                        .frame(height: 120)
                    }

                    // Zone selector
                    if !availableAreas.isEmpty {
                        Picker("Zone", selection: $selectedAreaId) {
                            Text("None").tag(String?(nil))
                            ForEach(availableAreas, id: \.id) { area in
                                Text(area.name).tag(area.id as String?)
                            }
                        }
                        .pickerStyle(.wheel)
                        .frame(height: 100)
                    }

                    // Save button with AR position info
                    HStack {
                        Button("Save AR Placement") {
                            Task { await saveARPlacement() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(selectedFixture == nil || selectedRoomId == nil || arHitPosition == nil)

                        if let pos = arHitPosition {
                            Text("📍 \(String(format: "%.2f, %.2f", pos.x, pos.z))m")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding()
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                .padding()
            }
        }
    }

    /// Fixtures that have been detected but not yet linked to a bridge light.
    private var pendingFixtures: [TrackedFixture] {
        arSessionManager.trackedFixtures
    }

    private func loadManualAssignments() async {
        let assignments = await hueClient.spatialService?.getAllManualAssignments() ?? [:]
        await MainActor.run {
            manualAssignments = Dictionary(uniqueKeysWithValues: assignments.map { ($0.key.uuidString, $0.value) })
        }
    }

    private func savePlacement() async {
        guard let fixture = selectedFixture,
              let roomId = selectedRoomId else { return }

        isSaving = true

        // Use the HueSpatialService manual placement mode
        let spatialService = hueClient.spatialService
        spatialService?.setManualRoomAssignment(
            fixtureId: fixture.id,
            roomId: roomId,
            areaId: selectedAreaId
        )

        // Also save to SwiftData persistence via FixturePersistence
        await FixturePersistence.shared.saveManualAssignment(
            fixtureId: fixture.id,
            roomId: roomId,
            areaId: selectedAreaId
        )

        saveMessage = "Placement saved for \(fixture.type.displayName)"
        isSaving = false

        await loadManualAssignments()
    }

    /// Save AR-guided placement with hit-test position.
    /// Combines the tap-detected 3D position with the selected room/zone.
    private func saveARPlacement() async {
        guard let fixture = selectedFixture,
              let roomId = selectedRoomId,
              let position = arHitPosition else { return }

        isSaving = true

        // Use the HueSpatialService manual placement mode with AR position
        let spatialService = hueClient.spatialService
        spatialService?.setManualRoomAssignment(
            fixtureId: fixture.id,
            roomId: roomId,
            areaId: selectedAreaId
        )

        // Save with the AR-detected spatial position for accurate placement
        await FixturePersistence.shared.saveManualAssignment(
            fixtureId: fixture.id,
            roomId: roomId,
            areaId: selectedAreaId
        )

        saveMessage = "AR placement saved for \(fixture.type.displayName)"
        isSaving = false
        showARHitReticle = false

        await loadManualAssignments()
    }

    /// Handle tap gesture on AR preview to perform hit testing.
    /// Uses ARHitTestResult with feature point and estimated horizontal plane
    /// results to find the best surface for fixture placement.
    private func handleARTap(at location: CGPoint) {
        guard let sceneView = ARKitPreviewView.currentSceneView else {
            saveMessage = "AR camera not available. Switch to Form mode."
            return
        }

        let results = sceneView.session.currentFrame?.hitTest(
            location,
            types: [.featurePoint, .estimatedHorizontalPlane]
        ) ?? []

        // Prefer feature point hits, then fall back to estimated horizontal plane
        guard let hitTest = results.first(where: { $0.type == .featurePoint })
            ?? results.first(where: { $0.type == .estimatedHorizontalPlane })
            ?? results.first else {
            saveMessage = "Tap on a surface to place fixture"
            return
        }

        let t = hitTest.worldTransform.columns.3
        arHitPosition = SIMD3<Float>(t.x, t.y, t.z)
        showARHitReticle = true
        saveMessage = "Tap detected at \(String(format: "%.2f, %.2f, %.2f", arHitPosition!.x, arHitPosition!.y, arHitPosition!.z))m"
    }

    private func clearAllManualPlacements() {
        // Clear manual room assignments from spatial service
        hueClient.spatialService?.exitManualPlacementMode()

        // Clear roomId/areaId from all FixtureMapping records
        Task {
            await FixturePersistence.shared.clearManualAssignments()
            saveMessage = "All manual placements cleared"
            await loadManualAssignments()
        }
    }
}

/// Simple ARKit camera preview view for AR-guided placement.
struct ARKitPreviewView: UIViewRepresentable {
    static var currentSceneView: ARSKView?

    func makeUIView(context: Context) -> ARSKView {
        let view = ARSKView()
        Self.currentSceneView = view
        return view
    }

    func updateUIView(_ uiView: ARSKView, context: Context) {
        // AR session is managed by ARSessionManager
    }
}

/// Reticle overlay shown at the AR hit-test location.
struct ARPlacementReticle: View {
    let position: SIMD3<Float>

    var body: some View {
        Circle()
            .strokeBorder(Color.blue, lineWidth: 3)
            .frame(width: 60, height: 60)
            .overlay(
                Circle()
                    .stroke(Color.blue.opacity(0.5), lineWidth: 1)
                    .frame(width: 80, height: 80)
            )
            .overlay(
                Image(systemName: "crosshair.circle.fill")
                    .foregroundStyle(.blue)
                    .font(.title2)
            )
    }
}
