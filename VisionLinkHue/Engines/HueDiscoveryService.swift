import Foundation
import Network
import os

/// Service responsible for discovering Philips Hue bridges on the local network.
/// Uses mDNS (NetServiceBrowser) to find bridges advertising `_hue._tcp.` services.
@MainActor
final class HueDiscoveryService {
    
    private let logger = Logger(
        subsystem: "com.tomwolfe.visionlinkhue",
        category: "HueDiscovery"
    )
    
    /// Whether a discovery operation is currently in progress.
    var isDiscovering: Bool { browser != nil }
    
    /// Active network browser for mDNS discovery.
    private var browser: NWBrowser?
    
    /// Discover Hue bridges on the local network using mDNS.
    /// Uses a synchronous browser with a 3-second timeout.
    /// - Parameter stateStream: Optional state stream for error reporting.
    /// - Returns: Array of discovered bridge information.
    func discoverBridges(stateStream: HueStateStream?) async -> [BridgeInfo] {
        var discoveredBridges: [BridgeInfo] = []
        var seenIPs = Set<String>()
        let semaphore = DispatchSemaphore(value: 0)
        
        let serviceBrowser = NetServiceBrowser()
        let mdnsDelegate = MDNSDelegate(
            onFound: { [weak self] name, ip, port in
                if !seenIPs.contains(ip) {
                    seenIPs.insert(ip)
                    discoveredBridges.append(BridgeInfo(name: name, ip: ip, port: port))
                    self?.logger.info("Found Hue bridge: \(name) at \(ip):\(port)")
                }
            },
            onFinished: { semaphore.signal() }
        )
        serviceBrowser.delegate = mdnsDelegate
        
        serviceBrowser.searchForServices(ofType: "_hue._tcp.", inDomain: "local.")
        
        // Wait up to 3 seconds for discovery
        try? await Task.sleep(for: .seconds(3))
        serviceBrowser.stop()
        
        if discoveredBridges.isEmpty {
            await stateStream?.reportError(HueError.noBridgeConfigured, severity: .warning, source: "HueDiscoveryService.discover")
        }
        
        return discoveredBridges
    }
    
    /// Cancel any in-progress discovery operation.
    func cancelDiscovery() {
        browser?.cancel()
        browser = nil
    }
}

// MARK: - mDNS Delegate

/// Simple NetServiceBrowser delegate for Hue bridge discovery.
private final class MDNSDelegate: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    let onFound: (String, String, Int) -> Void
    let onFinished: () -> Void
    
    init(onFound: @escaping (String, String, Int) -> Void, onFinished: @escaping () -> Void) {
        self.onFound = onFound
        self.onFinished = onFinished
    }
    
    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        service.delegate = self
        service.resolve(withTimeout: 2.0)
    }
    
    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: Int]) {
        onFinished()
    }
    
    func netService(_ service: NetService, didResolve address: NetService) {
        if let addresses = service.addresses, !addresses.isEmpty {
            let addrData = addresses[0]
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
                    
                    let ip = result == 0 ? String(cString: hostname) : "unknown"
                    onFound(service.name, ip, service.port)
                }
            }
        }
    }
}
