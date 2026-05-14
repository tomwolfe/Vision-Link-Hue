import SwiftUI
import RealityKit
import ARKit

/// Main content view that orchestrates the entire AR experience.
/// Uses `@Environment` for dependency injection from `AppContainer`.
struct ContentView: View {
    
    @Environment(HueStateStream.self) private var stateStream
    @Environment(HueClient.self) private var hueClient
    @Environment(DetectionEngine.self) private var detectionEngine
    @Environment(ARSessionManager.self) private var arSessionManager
    @Environment(SpatialProjector.self) private var spatialProjector
    @Environment(DetectionSettings.self) private var detectionSettings
    
    @State private var showSettings: Bool = false
    @State private var showBridgeDiscovery: Bool = false
    @State private var dismissedErrorId: UUID?
    
    @State private var batterySaverMode: Bool = false
    @State private var extendedRelocalizationMode: Bool = false
    
    var body: some View {
        GeometryReader { geometry in
                let sessionManager = arSessionManager
                let detector = detectionEngine
                let client = hueClient
                let stream = stateStream
                let projector = spatialProjector
                ZStack {
                    // AR session view
                    ARViewContainer(
                        sessionManager: sessionManager,
                        detectionEngine: detector,
                        hueClient: client,
                        stateStream: stream,
                        spatialProjector: projector
                    )
                    .ignoresSafeArea()
                    
                    // HUD overlay
                    HUDOverlay(
                        sessionManager: sessionManager,
                        detectionEngine: detector,
                        hueClient: client,
                        stateStream: stream,
                        frameSize: geometry.size
                    )
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(
                hueClient: hueClient,
                stateStream: stateStream
            )
        }
        .sheet(isPresented: $showBridgeDiscovery) {
            BridgeDiscoveryView(
                hueClient: hueClient,
                stateStream: stateStream
            )
        }
        .overlay(alignment: .top) {
            if let error = stateStream.activeErrors.first(where: { $0.id != dismissedErrorId }) {
                errorToast(error)
                    .padding(.top, 60)
                    .onAppear {
                        if error.severity == .critical && error.source == "HueClient.reconnect" {
                            showBridgeDiscovery = true
                        }
                    }
            }
        }
        .task {
            // Auto-discover bridge on launch
            let bridges = await hueClient.discoverBridges()
            if bridges.count == 1 {
                await hueClient.connect(to: bridges.first!)
            } else if bridges.count > 1 {
                showBridgeDiscovery = true
            }
            
            // Handle certificate pin mismatch events
            hueClient.onCertificatePinMismatch = { [weak stateStream] newHash, oldHash in
                await stateStream?.reportCertificatePinMismatch(newHash: newHash, oldHash: oldHash)
            }
        }
    }
    
    @ViewBuilder
    private func errorToast(_ error: AppError) -> some View {
        HStack {
            Text(error.displayMessage)
                .font(.caption)
                .foregroundStyle(.primary)
            
            Spacer()
            
            Button {
                dismissedErrorId = error.id
                stateStream.dismissError(error)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel(Text("Dismiss error"))
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Rectangle())
        .shadow(radius: 5)
    }
}

/// Settings view for bridge configuration.
struct SettingsView: View {
    
    let hueClient: HueClient
    let stateStream: HueStateStream
    @Environment(\.dismiss) private var dismiss
    @Environment(DetectionSettings.self) private var detectionSettings
    @State private var batterySaverMode: Bool = false
    @State private var extendedRelocalizationMode: Bool = false
    
    var body: some View {
        NavigationStack {
            Form {
                // Bridge info
                Section("Bridge") {
                    HStack {
                        Text("Status")
                        Spacer()
                        Circle()
                            .fill(stateStream.isConnected ? .green : .red)
                            .frame(width: 10, height: 10)
                        Text(stateStream.isConnected ? "Connected" : "Disconnected")
                    }
                    
                    if let ip = hueClient.bridgeIP {
                        Text("IP: \(ip)")
                    }
                    
                    Text("Port: \(hueClient.bridgePort)")
                }
                
                // API Key
                Section("API Key") {
                    if let key = hueClient.apiKey {
                        Text(key.prefix(16) + "****")
                    }
                    
                    Button("Create New Key") {
                        Task {
                            do {
                                _ = try await hueClient.createApiKey()
                            } catch {
                                stateStream.reportError(error, severity: .error, source: "SettingsView.createApiKey")
                            }
                        }
                    }
                    .accessibilityLabel(Text("Create new API key"))
                    .accessibilityHint(Text("Generate a new API key for bridge authentication"))
                    .foregroundStyle(.blue)
                }
                
                // Light Groups
                Section("Light Groups") {
                    if stateStream.groups.isEmpty {
                        Text("No groups available")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(stateStream.groups, id: \.id) { group in
                            Button {
                                stateStream.selectedGroupId = group.id
                            } label: {
                                HStack {
                                    Text(group.name)
                                    Spacer()
                                    if stateStream.selectedGroupId == group.id {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(.blue)
                                    }
                                }
                            }
                            .accessibilityLabel(Text(group.name))
                            .accessibilityHint(Text("Select light group"))
                        }
                    }
                }
                
                // Lights
                Section("Lights (\(stateStream.lights.count))") {
                    ForEach(stateStream.lights.prefix(10)) { light in
                        HStack {
                            Text(light.metadata.name ?? light.id)
                            Spacer()
                            if light.state.on ?? false {
                                Image(systemName: "lightbulb.fill")
                                    .foregroundStyle(.yellow)
                            } else {
                                Image(systemName: "lightbulb")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    
                    if stateStream.lights.count > 10 {
                        Text("... and \(stateStream.lights.count - 10) more")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                }
                
                // Spatial
                Section("Spatial") {
                    if hueClient.spatialService?.isSpatialAwareSupported == true {
                        Text("SpatialAware: Available")
                            .foregroundStyle(.green)
                    } else {
                        Text("SpatialAware: Not available (older bridge)")
                            .foregroundStyle(.secondary)
                        
                        NavigationLink {
                            ManualPlacementView()
                        } label: {
                            Text("Manual Placement")
                        }
                    }
                }
                
                // Detection
                Section("Detection") {
                    HStack {
                        Text("Battery Saver")
                        Spacer()
                        Toggle("", isOn: $batterySaverMode)
                            .labelsHidden()
                    }
                    Text("Disables Neural Surface Synthesis material classification to reduce battery usage")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    
                    HStack {
                        Text("Extended Relocalization")
                        Spacer()
                        Toggle("", isOn: $extendedRelocalizationMode)
                            .labelsHidden()
                    }
                    Text("Anchors all fixture types for better relocalization in feature-sparse environments")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                // Actions
                Section {
                    Button("Reconnect") {
                        Task { await hueClient.reconnect() }
                    }
                    .accessibilityLabel(Text("Reconnect to bridge"))
                    .accessibilityHint(Text("Attempt to reconnect to the Hue bridge"))
                    .foregroundStyle(.blue)
                    
                    Button("Disconnect") {
                        hueClient.disconnect()
                    }
                    .accessibilityLabel(Text("Disconnect from bridge"))
                    .accessibilityHint(Text("Disconnect from the Hue bridge"))
                    .foregroundStyle(.red)
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .task {
                batterySaverMode = detectionSettings.batterySaverMode
                extendedRelocalizationMode = detectionSettings.extendedRelocalizationMode
            }
            .onChange(of: batterySaverMode) { _, newValue in
                detectionSettings.batterySaverMode = newValue
            }
            .onChange(of: extendedRelocalizationMode) { _, newValue in
                detectionSettings.extendedRelocalizationMode = newValue
            }
        }
    }
}
