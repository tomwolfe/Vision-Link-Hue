import Foundation
import MultipeerConnectivity
import os

/// Service for discovering Matter-compatible Thread border routers and accessories
/// using MultipeerConnectivity as a local network discovery fallback.
///
/// Works alongside HomeKit's native accessory discovery to provide additional
/// discovery surface for Matter devices on the Thread network.
@MainActor
final class MatterDiscoveryService {
    
    // MARK: - State
    
    /// Whether the service is currently active and discovering.
    var isDiscovering: Bool { session?.state != .notConnected }
    
    /// Discovered Matter border routers.
    var discoveredBorderRouters: [MatterBorderRouter] {
        _discoveredRouters.values.map { routerInfo in
            MatterBorderRouter(
                id: routerInfo.advertiserName,
                name: routerInfo.displayName,
                manufacturer: routerInfo.manufacturer,
                model: routerInfo.model,
                isOnline: routerInfo.isConnected,
                threadNetworkName: routerInfo.threadNetworkName
            )
        }
    }
    
    // MARK: - Private State
    
    private let logger = Logger(
        subsystem: "com.tomwolfe.visionlinkhue",
        category: "MatterDiscovery"
    )
    
    private let serviceType = "visionlinkhue-matter-discovery"
    
    private var session: MCSession?
    private var browser: MCBrowserViewController?
    private var advertiser: MCAdvertiserAssistant?
    
    /// Discovered router information keyed by advertiser name.
    private var _discoveredRouters: [String: RouterInfo] = [:]
    
    /// Callback for discovered border routers.
    var onBorderRouterDiscovered: (@Sendable (MatterBorderRouter) -> Void)?
    
    /// Callback for lost border routers.
    var onBorderRouterLost: (@Sendable (String) -> Void)?
    
    // MARK: - Initialization
    
    init() {
        // Session created lazily when discovery starts
    }
    
    // MARK: - Discovery
    
    /// Start discovering Matter Thread border routers on the local network.
    func startDiscovery() {
        guard !isDiscovering else {
            logger.debug("Matter discovery already active")
            return
        }
        
        let peerID = MCPeerID(displayName: "Vision-Link-Hue-\(UUID().uuidString.prefix(8))")
        let session = MCSession(peer: peerID)
        session.delegate = self as? MCSessionDelegate
        self.session = session
        
        let advertiser = MCAdvertiserAssistant(
            serviceType: serviceType,
            discoveryInfo: ["version": "1.0", "type": "matter-fallback"],
            session: session
        )
        advertiser.start()
        self.advertiser = advertiser
        
        logger.info("Started Matter border router discovery")
    }
    
    /// Stop discovering Matter Thread border routers.
    func stopDiscovery() {
        advertiser?.stop()
        self.advertiser = nil
        session?.disconnect()
        self.session = nil
        _discoveredRouters.removeAll()
        logger.info("Stopped Matter border router discovery")
    }
    
    /// Discover Matter devices and return the results.
    func discoverDevices() async -> [MatterBorderRouter] {
        if !isDiscovering {
            startDiscovery()
            // Wait briefly for discovery to populate
            try? await Task.sleep(for: .seconds(3))
            stopDiscovery()
        }
        return discoveredBorderRouters
    }
    
    // MARK: - Private
    
    private func addOrUpdateRouter(_ info: RouterInfo) {
        _discoveredRouters[info.advertiserName] = info
        
        let router = MatterBorderRouter(
            id: info.advertiserName,
            name: info.displayName,
            manufacturer: info.manufacturer,
            model: info.model,
            isOnline: info.isConnected,
            threadNetworkName: info.threadNetworkName
        )
        
        onBorderRouterDiscovered?(router)
    }
    
    private func removeRouter(_ advertiserName: String) {
        _discoveredRouters.removeValue(forKey: advertiserName)
        onBorderRouterLost?(advertiserName)
    }
}

// MARK: - Router Info

/// Internal representation of a discovered router's advertising data.
struct RouterInfo: Sendable {
    let advertiserName: String
    let displayName: String
    let manufacturer: String
    let model: String
    let isConnected: Bool
    let threadNetworkName: String?
}

// MARK: - MCSessionDelegate Conformance

extension MatterDiscoveryService: MCSessionDelegate {
    
    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        Task { [weak self] in
            guard let self else { return }
            
            do {
                let decoder = JSONDecoder()
                let info = try decoder.decode(RouterInfo.self, from: data)
                await self.addOrUpdateRouter(info)
            } catch {
                self.logger.error("Failed to decode router info from peer \(peerID.displayName): \(error.localizedDescription)")
            }
        }
    }
    
    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {
        // Stream-based data transfer not used for discovery
    }
    
    func session(_ session: MCSession, didChange state: MCSessionState, fromPeer peerID: MCPeerID) {
        Task { [weak self] in
            guard let self else { return }
            
            switch state {
            case .connected:
                let info = RouterInfo(
                    advertiserName: peerID.displayName,
                    displayName: peerID.displayName,
                    manufacturer: "Unknown",
                    model: "Unknown",
                    isConnected: true,
                    threadNetworkName: nil
                )
                await self.addOrUpdateRouter(info)
            case .notConnected:
                await self.removeRouter(peerID.displayName)
            case .connecting:
                break
            @unknown default:
                break
            }
        }
    }
    
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        // Deprecated in newer iOS versions, handled by didChange(state:fromPeer:)
    }
    
    func session(_ session: MCSession, didNotStartPeer peerID: MCPeerID, error: Error?) {
        logger.debug("Failed to connect to peer \(peerID.displayName): \(error?.localizedDescription ?? "unknown error")")
    }
}
