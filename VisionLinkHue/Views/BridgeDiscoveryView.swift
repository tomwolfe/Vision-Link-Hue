import SwiftUI
import RealityKit
import ARKit

/// Bridge discovery and connection sheet.
struct BridgeDiscoveryView: View {
    
    let hueClient: HueClient
    let stateStream: HueStateStream
    @Environment(\.dismiss) private var dismiss
    
    @State private var bridges: [BridgeInfo] = []
    @State private var isDiscovering: Bool = false
    @State private var isLoading: Bool = false
    @State private var showManualEntry: Bool = false
    @State private var manualIP: String = ""
    @State private var manualPort: String = "443"
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if isDiscovering {
                    ProgressView("Discovering bridges...")
                        .padding()
                } else if bridges.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "wifi")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        
                        Text("No bridges found")
                            .font(.headline)
                        
                        Text("Make sure your Hue bridge is powered on and connected to the same network.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        
                        Button("Try Again") {
                            Task { await discover() }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.blue)
                        .accessibilityLabel(Text("Try bridge discovery again"))
                        .accessibilityHint(Text("Search for Hue bridges on the network again"))
                        
                        Button("Enter IP Manually") {
                            withAnimation(.smooth) {
                                showManualEntry = true
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.blue)
                        .accessibilityLabel(Text("Enter bridge IP manually"))
                        .accessibilityHint(Text("Manually specify the bridge network address"))
                    }
                    .padding()
                } else {
                    List(bridges) { bridge in
                        Button {
                            Task {
                                isLoading = true
                                await hueClient.connect(to: bridge)
                                isLoading = false
                            }
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(bridge.name)
                                        .font(.headline)
                                    Text("\(bridge.ip):\(bridge.port)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                
                                Spacer()
                                
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityLabel(Text(bridge.name))
                        .accessibilityHint(Text("Connect to \(bridge.name) at \(bridge.ip)"))
                    }
                }
                
                if let error = stateStream.activeErrors.first {
                    Text(error.displayMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.horizontal)
                }
                
                if showManualEntry {
                    HStack(spacing: 8) {
                        TextField("Bridge IP (e.g., 192.168.1.1)", text: $manualIP)
                            .keyboardType(.URL)
                            .autocapitalization(.none)
                        
                        TextField("Port", text: $manualPort)
                            .keyboardType(.numberPad)
                    }
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal)
                    
                    Button("Connect") {
                        Task {
                            let port = Int(manualPort) ?? 443
                            let bridge = BridgeInfo(
                                name: "Hue Bridge (manual)",
                                ip: manualIP,
                                port: port
                            )
                            await hueClient.connect(to: bridge)
                            dismiss()
                        }
                    }
                    .padding(.horizontal)
                }
            }
            .navigationTitle("Hue Bridge")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task {
                if bridges.isEmpty {
                    await discover()
                }
            }
        }
    }
    
    private func discover() async {
        isDiscovering = true
        bridges = await hueClient.discoverBridges()
        isDiscovering = false
    }
}
