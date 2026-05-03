import SwiftUI
import RealityKit
import ARKit

/// Main content view that orchestrates the entire AR experience.
/// Uses `@State` with `@Observable` types for granular dependency tracking.
struct ContentView: View {
    
    @State private var stateStream: HueStateStream
    @State private var hueClient: HueClient
    @State private var detectionEngine: DetectionEngine
    @State private var arSessionManager: ARSessionManager
    @State private var spatialProjector: SpatialProjector
    
    init() {
        let persistence = FixturePersistence.shared
        let stream = HueStateStream(persistence: persistence)
        stream.configure()
        let client = HueClient(stateStream: stream)
        let detector = DetectionEngine()
        let projector = SpatialProjector()
        let manager = ARSessionManager(
            detectionEngine: detector,
            spatialProjector: projector,
            hueClient: client,
            stateStream: stream
        )
        
        _stateStream = State(initialValue: stream)
        _hueClient = State(initialValue: client)
        _detectionEngine = State(initialValue: detector)
        _arSessionManager = State(initialValue: manager)
        _spatialProjector = State(initialValue: projector)
    }
    
    @State private var showSettings: Bool = false
    @State private var dismissedErrorId: UUID?
    @State private var arViewRef: ARView?
    
    var body: some View {
        GeometryReader { geometry in
                // AR session view
                let sessionManager = arSessionManager
                let detector = detectionEngine
                let client = hueClient
                let stream = stateStream
                let projector = spatialProjector
                ZStack {
                    // AR session view
                    ARViewContainer(
                        sessionManager: sessionManager,
                        onFrameUpdate: { frame in
                            Task {
                                await sessionManager.didUpdateFrame(frame)
                            }
                        },
                        onARViewReady: { arView in
                            arViewRef = arView
                            Task {
                                await sessionManager.configureAndStart(in: arView)
                            }
                        }
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
        .shadow(radius: 5)
    }
}

/// Settings view for bridge configuration.
struct SettingsView: View {
    
    let hueClient: HueClient
    let stateStream: HueStateStream
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
                                await stateStream.reportError(error, severity: .error, source: "SettingsView.createApiKey")
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
