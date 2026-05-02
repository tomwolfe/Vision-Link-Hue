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
    @State private var dismissedErrorId: UUID?
    
    init() {
        _stateStream = StateObject(wrappedValue: HueStateStream())
        
        let client = HueClient(stateStream: stateStream)
        _hueClient = StateObject(wrappedValue: client)
        
        let detector = DetectionEngine()
        let projector = SpatialProjector()
        
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
    
    @State private var arViewRef: ARView?
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // AR session view
                ARViewContainer(
                    sessionManager: arSessionManager,
                    onFrameUpdate: { frame in
                        Task {
                            await arSessionManager.didUpdateFrame(frame)
                        }
                    },
                    onARViewReady: { arView in
                        arViewRef = arView
                        Task {
                            await arSessionManager.configureAndStart(in: arView)
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
        .overlay(alignment: .top) {
            if let error = stateStream.activeErrors.first(where: { $0.id != dismissedErrorId }) {
                errorToast(error)
                    .padding(.top, 60)
            }
        }
        .task {
            // Auto-discover bridge on launch
            let bridges = await hueClient.discoverBridges()
            if let first = bridges.first {
                await hueClient.connect(to: first)
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
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Rectangle())
        .glassEffect(.liquid, alignment: .center)
        .shadow(radius: 5)
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
                            .fill(stateStream.isConnected ? .green : .red)
                            .frame(width: 10, height: 10)
                        Text(stateStream.isConnected ? "Connected" : "Disconnected")
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
