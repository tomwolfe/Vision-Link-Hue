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
    
    /// Holds the active mDNS delegate to prevent deallocation.
    private var activeMDNSDelegate: MDNSDelegate?
    
    /// Discover Hue bridges on the local network using mDNS.
    /// Uses an adaptive timeout that extends if services are still being
    /// discovered, accommodating congested Wi-Fi 7 / Thread environments
    /// where mDNS resolution can take 4-5 seconds.
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
        self.activeMDNSDelegate = mdnsDelegate
        serviceBrowser.delegate = mdnsDelegate
        
        serviceBrowser.searchForServices(ofType: "_hue._tcp.", inDomain: "local.")
        
        // Adaptive timeout: wait at least 3 seconds, then check if new
        // services are still arriving. If so, extend by up to 2 more
        // seconds in 1-second increments to accommodate slower devices.
        let baseTimeout: TimeInterval = 3.0
        let maxAdaptiveExtension: TimeInterval = 2.0
        let checkInterval: TimeInterval = 1.0
        
        let startTime = ContinuousClock.now
        var lastDiscoveryCount = 0
        
        while true {
            let elapsed = ContinuousClock.now - startTime
            let remainingBase = baseTimeout - Double(elapsed.components.seconds)
            
            if remainingBase > 0 {
                // Still within base timeout period, sleep for up to 1 second
                let sleepDuration = min(checkInterval, remainingBase)
                try? await Task.sleep(for: .seconds(sleepDuration))
            } else {
                // Base timeout reached, check for adaptive extension
                if elapsed.components.seconds >= Int(baseTimeout + maxAdaptiveExtension) {
                    // Maximum timeout reached
                    break
                }
                
                // Check if new services were discovered since last check
                if discoveredBridges.count == lastDiscoveryCount {
                    // No new discoveries, safe to stop
                    break
                }
                
                lastDiscoveryCount = discoveredBridges.count
                try? await Task.sleep(for: .seconds(checkInterval))
            }
        }
        
        serviceBrowser.stop()
        self.activeMDNSDelegate = nil
        
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
private final class MDNSDelegate: NSObject, NetServiceBrowserDelegate {
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
}

extension MDNSDelegate: NetServiceDelegate {
    func netServiceDidResolveAddress(_ sender: NetService) {
        if let addresses = sender.addresses, !addresses.isEmpty {
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
                    onFound(sender.name, ip, sender.port)
                }
            }
        }
    }
    
    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: Int]) {
        onFinished()
    }
}
