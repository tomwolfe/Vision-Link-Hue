import Foundation
import os
import UIKit

/// Service for discovering Matter-compatible Thread border routers and accessories
/// using mDNS (Bonjour) discovery on the local network.
///
/// Thread Border Routers (Apple TV, HomePod, Nest Hub, etc.) advertise themselves
/// via standard mDNS service types: `_matter._tcp.` and `_meshcop._udp.`.
/// This service actively browses for these services instead of relying on
/// peer-to-peer MultipeerConnectivity, which Thread Border Routers do not support.
///
/// Automatically suspends discovery when the app backgrounds or when a stable
/// Hue Bridge connection is established to minimize battery drain.
final class MatterDiscoveryService: NSObject, @unchecked Sendable {
    
    // MARK: - State
    
    /// Whether the service is currently active and discovering.
    var isDiscovering: Bool { _isDiscovering }
    private var _isDiscovering: Bool = false
    
    /// Controls whether discovery should be suspended due to external factors
    /// (app backgrounding or stable bridge connection).
    private var isSuspended: Bool = false
    
    /// Whether a stable Hue Bridge connection is established.
    /// When true, aggressively suspends mDNS discovery to conserve battery.
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
    
    /// Discovered Matter border routers (actor-isolated for thread safety).
    func getDiscoveredBorderRouters() async -> [MatterBorderRouter] {
        let routerInfos = await _routerStore.values
        return routerInfos.map { routerInfo in
            MatterBorderRouter(
                id: routerInfo.name,
                name: routerInfo.displayName,
                manufacturer: routerInfo.manufacturer,
                model: routerInfo.model,
                isOnline: true,
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
    
    /// mDNS service types used by Matter 1.5 Thread Border Routers.
    private let matterServiceType = "_matter._tcp."
    private let meshcopServiceType = "_meshcop._udp."
    
    /// Browser for discovering Matter services on the local network.
    private var browser: NetServiceBrowser?
    
    /// Actor-isolated store for tracking resolved NetService instances,
    /// protecting against data races between delegate callbacks on arbitrary
    /// threads and stopDiscovery() on the calling executor.
    private actor ServicesStore {
        private var _services: [NetService] = []
        
        var count: Int { _services.count }
        
        func append(_ service: NetService) {
            _services.append(service)
        }
        
        func removeAll(where predicate: (NetService) -> Bool) {
            _services.removeAll(where: predicate)
        }
        
        func removeAll() {
            _services.removeAll()
        }
    }
    
    private let _servicesStore = ServicesStore()
    
    /// Actor-isolated store for discovered router information, protecting
    /// against data races between delegate callbacks and discovery queries.
    private actor RouterStore {
        private var _routers: [String: RouterInfo] = [:]
        
        var values: [RouterInfo] { _routers.values }
        
        func addOrUpdate(_ info: RouterInfo) {
            _routers[info.name] = info
        }
        
        func remove(_ name: String) {
            _routers.removeValue(forKey: name)
        }
        
        func clear() {
            _routers.removeAll()
        }
    }
    
    private let _routerStore = RouterStore()
    
    /// Callback for discovered border routers.
    var onBorderRouterDiscovered: (@Sendable (MatterBorderRouter) -> Void)?
    
    /// Callback for lost border routers.
    var onBorderRouterLost: (@Sendable (String) -> Void)?
    
    // MARK: - Initialization
    
    override init() {
        super.init()
    }
    
    // MARK: - Discovery
    
    /// Start discovering Matter Thread border routers on the local network
    /// via mDNS (Bonjour) browsing.
    func startDiscovery() {
        guard !isDiscovering else {
            logger.debug("Matter discovery already active")
            return
        }
        
        browser = NetServiceBrowser()
        browser?.delegate = self
        
        _isDiscovering = true
        logger.info("Started Matter border router mDNS discovery")
    }
    
    /// Stop discovering Matter Thread border routers.
    func stopDiscovery() async {
        browser?.stop()
        browser = nil
        
        await _servicesStore.removeAll()
        
        await _routerStore.clear()
        _isDiscovering = false
        isSuspended = false
        logger.info("Stopped Matter border router discovery")
    }
    
    /// Suspend discovery due to app backgrounding or stable bridge connection.
    /// This conserves battery by stopping the browser without fully disconnecting.
    func suspendDiscovery() {
        guard isDiscovering && !isSuspended else { return }
        isSuspended = true
        browser?.stop()
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
            await stopDiscovery()
        }
        let routerInfos = await _routerStore.values
        return routerInfos.map { routerInfo in
            MatterBorderRouter(
                id: routerInfo.name,
                name: routerInfo.displayName,
                manufacturer: routerInfo.manufacturer,
                model: routerInfo.model,
                isOnline: true,
                threadNetworkName: routerInfo.threadNetworkName,
                rssi: nil,
                areaMetadata: routerInfo.areaMetadata
            )
        }
    }
    
    // MARK: - Private
    
    private func addOrUpdateRouter(_ info: RouterInfo) async {
        await _routerStore.addOrUpdate(info)
        
        let router = MatterBorderRouter(
            id: info.name,
            name: info.displayName,
            manufacturer: info.manufacturer,
            model: info.model,
            isOnline: true,
            threadNetworkName: info.threadNetworkName,
            rssi: nil,
            areaMetadata: info.areaMetadata
        )
        
        onBorderRouterDiscovered?(router)
    }
    
    private func removeRouter(_ name: String) async {
        await _routerStore.remove(name)
        onBorderRouterLost?(name)
    }
}

// MARK: - Router Info

/// Internal representation of a discovered router's advertising data.
/// Includes area metadata for Matter 1.5.1+ Thread Border Routers.
struct RouterInfo: Sendable {
    let name: String
    let displayName: String
    let manufacturer: String
    let model: String
    let threadNetworkName: String?
    let areaMetadata: MatterAreaMetadata?
}

// MARK: - NetServiceBrowserDelegate

extension MatterDiscoveryService: NetServiceBrowserDelegate {
    
    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        logger.debug("Found mDNS service: \(service.name) (\(service.type))")
        
        // Resolve the service to get its TXT record and port
        service.delegate = self
        service.resolve(withTimeout: 5.0)
        
        // Track the service for cleanup (actor-isolated to prevent data races)
        Task { await _servicesStore.append(service) }
    }
    
    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        logger.debug("Removed mDNS service: \(service.name)")
        
        // Remove from tracked services (actor-isolated to prevent data races)
        Task { await _servicesStore.removeAll { $0 == service } }
        
        // Remove from discovered routers
        Task { @MainActor [name = service.name] in
            await self.removeRouter(name)
        }
    }
    
    func netServiceBrowserDidStopSearch(_ browser: NetServiceBrowser) {
        logger.debug("mDNS search stopped")
        _isDiscovering = false
    }
}

// MARK: - NetServiceDelegate

extension MatterDiscoveryService: NetServiceDelegate {
    
    func netService(_ sender: NetService, didResolve _: NetService) {
        // Extract needed data before entering async context to avoid data races
        let name = sender.name
        let port = sender.port
        let type = sender.type
        let addresses = sender.addresses
        
        Task { @MainActor [weak self] in
            guard let self else { return }
            
            var displayName = String(name.dropLast(type.count + 1)) ?? "Unknown Device"
            var manufacturer: String?
            var model: String?
            var threadNetworkName: String?
            var areaMetadata: MatterAreaMetadata?
            
            if let addresses, !addresses.isEmpty {
                if let addrData = addresses.first {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    addrData.withUnsafeBytes { ptr in
                        let addrPtr = ptr.baseAddress?.assumingMemoryBound(to: sockaddr.self)
                        if let addrPtr {
                            let result = getnameinfo(
                                addrPtr,
                                socklen_t(addrData.count),
                                &hostname,
                                socklen_t(hostname.count),
                                nil,
                                0,
                                NI_NUMERICHOST
                            )
                            if result == 0 {
                                displayName = String(cString: hostname)
                            }
                        }
                    }
                }
            }
            
            let info = RouterInfo(
                name: name,
                displayName: displayName,
                manufacturer: manufacturer ?? "Unknown",
                model: model ?? "Unknown",
                threadNetworkName: threadNetworkName,
                areaMetadata: areaMetadata
            )
            
            await self.addOrUpdateRouter(info)
        }
    }
    
    func netServiceDidStop(_ sender: NetService) {
        logger.debug("mDNS service stopped: \(sender.name)")
    }
    
    func netService(_ sender: NetService, didNotResolve _: NetService) {
        logger.debug("Failed to resolve mDNS service: \(sender.name)")
    }
}
