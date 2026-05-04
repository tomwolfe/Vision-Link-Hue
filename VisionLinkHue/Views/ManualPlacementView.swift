import SwiftUI
import SwiftData

/// View for manually assigning room and zone to fixtures when
/// SpatialAware features are unavailable (older Bridge hardware).
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
            .navigationTitle("Manual Placement")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .onAppear {
                Task { await loadManualAssignments() }
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
            manualAssignments = assignments
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
