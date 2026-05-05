import Foundation
@preconcurrency import MultipeerConnectivity
import os
import UIKit

/// Service for discovering Matter-compatible Thread border routers and accessories
/// using MultipeerConnectivity as a local network discovery fallback.
///
/// Works alongside HomeKit's native accessory discovery to provide additional
/// discovery surface for Matter devices on the Thread network.
///
/// Automatically suspends discovery when the app backgrounds or when a stable
/// Hue Bridge connection is established to minimize battery drain.
final class MatterDiscoveryService: NSObject, @unchecked Sendable {
    
    // MARK: - State
    
    /// Whether the service is currently active and discovering.
    var isDiscovering: Bool { _isConnected }
    
    /// Tracks whether the MCSession is connected.
    private var _isConnected: Bool = false
    
    /// Controls whether discovery should be suspended due to external factors
    /// (app backgrounding or stable bridge connection).
    private var isSuspended: Bool = false
    
    /// Whether a stable Hue Bridge connection is established.
    /// When true, aggressively suspends Multipeer discovery to conserve battery.
    var isBridgeConnected: Bool {
        get { _isBridgeConnected }
        set {
            _isBridgeConnected = newValue
            if newValue {
                suspendDiscovery()
            }
        }
    }
    private var _isBridgeConnected: Bool = false
    
    /// Discovered Matter border routers.
    var discoveredBorderRouters: [MatterBorderRouter] {
        _discoveredRouters.values.map { routerInfo in
            MatterBorderRouter(
                id: routerInfo.advertiserName,
                name: routerInfo.displayName,
                manufacturer: routerInfo.manufacturer,
                model: routerInfo.model,
                isOnline: routerInfo.isConnected,
                threadNetworkName: routerInfo.threadNetworkName,
                rssi: nil,
                areaMetadata: routerInfo.areaMetadata
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
    
    override init() {
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
        isSuspended = false
        logger.info("Stopped Matter border router discovery")
    }
    
    /// Suspend discovery due to app backgrounding or stable bridge connection.
    /// This aggressively conserves battery by stopping the advertiser without
    /// fully disconnecting the session.
    func suspendDiscovery() {
        guard isDiscovering && !isSuspended else { return }
        isSuspended = true
        advertiser?.stop()
        self.advertiser = nil
        logger.debug("Matter discovery suspended for battery conservation")
    }
    
    /// Resume discovery after suspension (app foregrounded or bridge disconnected).
    func resumeDiscovery() {
        guard isSuspended else { return }
        isSuspended = false
        if !isBridgeConnected {
            startDiscovery()
        }
        logger.debug("Matter discovery resumed")
    }
    
    /// Register for lifecycle notifications to auto-suspend on background.
    func registerForLifecycleNotifications() {
        let nc = NotificationCenter.default
        nc.addObserver(
            self,
            selector: #selector(handleApplicationDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        nc.addObserver(
            self,
            selector: #selector(handleApplicationWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
    }
    
    /// Unregister from lifecycle notifications.
    func unregisterForLifecycleNotifications() {
        NotificationCenter.default.removeObserver(self)
    }
    
    @objc private func handleApplicationDidEnterBackground() {
        suspendDiscovery()
    }
    
    @objc private func handleApplicationWillEnterForeground() {
        if !isBridgeConnected {
            resumeDiscovery()
        }
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
            threadNetworkName: info.threadNetworkName,
            rssi: nil,
            areaMetadata: info.areaMetadata
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
/// Includes area metadata for Matter 1.5.1+ Thread Border Routers.
struct RouterInfo: Sendable, Decodable {
    let advertiserName: String
    let displayName: String
    let manufacturer: String
    let model: String
    let isConnected: Bool
    let threadNetworkName: String?
    let areaMetadata: MatterAreaMetadata?
}

// MARK: - MCSessionDelegate Conformance

extension MatterDiscoveryService: MCSessionDelegate {
    
    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        Task { @MainActor [weak self] in
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
        Task { @MainActor [weak self] in
            guard let self else { return }
            
            switch state {
            case .connected:
                _isConnected = true
                let info = RouterInfo(
                    advertiserName: peerID.displayName,
                    displayName: peerID.displayName,
                    manufacturer: "Unknown",
                    model: "Unknown",
                    isConnected: true,
                    threadNetworkName: nil,
                    areaMetadata: nil
                )
                await self.addOrUpdateRouter(info)
            case .notConnected:
                _isConnected = false
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
    
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: (any Error)?) {
        // Resource transfer not used for discovery
    }
    
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {
        // Resource transfer not used for discovery
    }
    
    func session(_ session: MCSession, didNotStartPeer peerID: MCPeerID, error: Error?) {
        logger.debug("Failed to connect to peer \(peerID.displayName): \(error?.localizedDescription ?? "unknown error")")
    }
}
