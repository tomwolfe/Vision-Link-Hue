import SwiftUI
import RealityKit
import ARKit

/// Main content view that orchestrates the entire AR experience.
struct ContentView: View {
    
    @StateObject private var stateStream = HueStateStream()
    @StateObject private var hueClient: HueClient
    @StateObject private var detectionEngine = DetectionEngine()
    @StateObject private var spatialProjector: SpatialProjector
    @StateObject private var arSessionManager: ARSessionManager
    
    @State private var showSettings: Bool = false
    
    init() {
        _stateStream = StateObject(wrappedValue: HueStateStream())
        
        let client = HueClient(stateStream: stateStream)
        _hueClient = StateObject(wrappedValue: client)
        
        let detector = DetectionEngine()
        let projector = SpatialProjector(session: ARWorldTrackingConfiguration().session)
        
        let manager = ARSessionManager(
            detectionEngine: detector,
            spatialProjector: projector,
            hueClient: client,
            stateStream: stateStream
        )
        
        _detectionEngine = StateObject(wrappedValue: detector)
        _spatialProjector = StateObject(wrappedValue: projector)
        _arSessionManager = StateObject(wrappedValue: manager)
    }
    
    var body: some View {
        ZStack {
            // AR session view
            ARViewContainer(
                sessionManager: arSessionManager,
                onFrameUpdate: { frame in
                    Task {
                        await arSessionManager.didUpdateFrame(frame)
                    }
                }
            )
            .ignoresSafeArea()
            
            // HUD overlay
            HUDOverlay(
                sessionManager: arSessionManager,
                detectionEngine: detectionEngine,
                hueClient: hueClient,
                stateStream: stateStream,
                frameSize: .zero
            )
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(
                hueClient: hueClient,
                stateStream: stateStream
            )
        }
        .task {
            // Auto-discover bridge on launch
            let bridges = await hueClient.discoverBridges()
            if let first = bridges.first {
                await hueClient.connect(to: first)
            }
        }
    }
}

/// Settings view for bridge configuration.
struct SettingsView: View {
    
    @ObservedObject var hueClient: HueClient
    @ObservedObject var stateStream: HueStateStream
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            Form {
                // Bridge info
                Section("Bridge") {
                    HStack {
                        Text("Status")
                        Spacer()
                        Circle()
                            .fill(hueClient.is_connected ? .green : .red)
                            .frame(width: 10, height: 10)
                        Text(hueClient.is_connected ? "Connected" : "Disconnected")
                    }
                    
                    if let ip = hueClient.bridgeIP {
                        Text("IP: \(ip)")
                    }
                    
                    if let port = hueClient.bridgePort {
                        Text("Port: \(port)")
                    }
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
                                // handled by @Published error
                            }
                        }
                    }
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
                        }
                    }
                }
                
                // Lights
                Section("Lights (\(stateStream.lights.count))") {
                    ForEach(stateStream.lights.prefix(10)) { light in
                        HStack {
                            Text(light.metadata.name ?? light.id)
                            Spacer()
                            if let state = light.state, let on = state.on {
                                Image(systemName: on ? "lightbulb.fill" : "lightbulb")
                                    .foregroundStyle(on ? .yellow : .secondary)
                            }
                        }
                    }
                    
                    if stateStream.lights.count > 10 {
                        Text("... and \(stateStream.lights.count - 10) more")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                }
                
                // Actions
                Section {
                    Button("Reconnect") {
                        Task { await hueClient.reconnect() }
                    }
                    .foregroundStyle(.blue)
                    
                    Button("Disconnect") {
                        hueClient.disconnect()
                    }
                    .foregroundStyle(.red)
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}
