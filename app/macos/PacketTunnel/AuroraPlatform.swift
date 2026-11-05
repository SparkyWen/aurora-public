import Foundation
import Libbox
import Network
import NetworkExtension

/// Appends a breadcrumb to <AppGroup>/diag.log. Used to trace where the extension
/// hangs/fails during startup (syslog redacts our NSLog as <private>, and devicectl
/// can't read the app-group container — but the app itself can, and surfaces this).
func extDiag(_ msg: String) {
    let line = "[ext] \(msg)\n"
    // Fallback log that never depends on the App Group container being reachable
    // (if containerURL is nil the container write below is a no-op and we'd see
    // nothing). /tmp is writable by a non-sandboxed system extension.
    if let h = try? FileHandle(forWritingTo: URL(fileURLWithPath: "/tmp/aurora-ext.log")) {
        defer { try? h.close() }; h.seekToEndOfFile(); h.write(Data(line.utf8))
    } else {
        try? Data(line.utf8).write(to: URL(fileURLWithPath: "/tmp/aurora-ext.log"))
    }
    guard let c = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.aurora.vpn") else { return }
    let url = c.appendingPathComponent("diag.log")
    if let h = try? FileHandle(forWritingTo: url) {
        defer { try? h.close() }
        h.seekToEndOfFile()
        h.write(Data(line.utf8))
    } else {
        try? Data(line.utf8).write(to: url)
    }
}

/// Aurora's implementation of sing-box libbox's PlatformInterface + CommandServerHandler.
///
/// This is the NE↔libbox glue. The structure mirrors sing-box's official
/// `sing-box-for-apple` ExtensionPlatformInterface, adapted to the exact API
/// surface of the libbox we built (sing-box v1.13.12). The single most important
/// method is `openTun`: libbox calls it while starting the service, handing us the
/// TUN options it derived from the config's `tun` inbound; we translate those into
/// `NEPacketTunnelNetworkSettings` and hand back the tunnel file descriptor.
///
/// iOS note: the config uses a small TUN subnet (172.19.0.1/30) + `auto_route:true`,
/// so libbox supplies the route set and we add `NEIPv4Route.default()` as the
/// included route — full traffic flows through the tunnel at the routing layer
/// without ever assigning 0.0.0.0/0 as the interface address (per the iOS spec).
final class AuroraPlatform: NSObject {
    private weak var provider: PacketTunnelProvider?
    private var networkSettings: NEPacketTunnelNetworkSettings?
    // Go-backed listeners are rewrapped by gomobile on each callback. Compare
    // its exported reference number, not the temporary Objective-C proxy.
    private enum ListenerIdentity: Equatable {
        case go(Int32)
        case native(ObjectIdentifier)
    }

    private static func identity(of listener: any LibboxInterfaceUpdateListenerProtocol) -> ListenerIdentity {
        if let proxy = listener as? LibboxInterfaceUpdateListener,
           let reference = proxy._ref as? GoSeqRef {
            return .go(reference.refnum)
        }
        return .native(ObjectIdentifier(listener as AnyObject))
    }

    private final class InterfaceMonitorSession {
        let listener: any LibboxInterfaceUpdateListenerProtocol
        let identity: ListenerIdentity
        let monitor = NWPathMonitor()
        let ready = DispatchSemaphore(value: 0)
        // These fields and all monitor/timer operations belong to monitorQueue.
        var timer: DispatchSourceTimer?
        var lastReportedInterface: (name: String, index: Int32)?
        var startupFinished = false

        init(_ listener: any LibboxInterfaceUpdateListenerProtocol) {
            self.listener = listener
            identity = AuroraPlatform.identity(of: listener)
        }

        func finishStartup() {
            guard !startupFinished else { return }
            startupFinished = true
            ready.signal()
        }

        func cancel() {
            timer?.cancel()
            timer = nil
            monitor.cancel()
            monitor.pathUpdateHandler = nil
            lastReportedInterface = nil
            // close/reset can arrive before the initial path callback.
            finishStartup()
        }
    }

    // Only the current-session pointer uses this short lock. No callback,
    // queue wait or libbox operation executes while it is held.
    private let monitorLock = NSLock()
    private var interfaceMonitor: InterfaceMonitorSession?
    private static let monitorQueue = DispatchQueue(label: "aurora.ifmon")

    private func currentMonitor() -> InterfaceMonitorSession? {
        monitorLock.lock()
        defer { monitorLock.unlock() }
        return interfaceMonitor
    }

    private func isCurrent(_ session: InterfaceMonitorSession) -> Bool {
        currentMonitor() === session
    }

    private func takeMonitor(matching listener: (any LibboxInterfaceUpdateListenerProtocol)? = nil) -> InterfaceMonitorSession? {
        let identity = listener.map { Self.identity(of: $0) }
        monitorLock.lock()
        defer { monitorLock.unlock() }
        if let identity, interfaceMonitor?.identity != identity { return nil }
        let retired = interfaceMonitor
        interfaceMonitor = nil
        return retired
    }

    init(provider: PacketTunnelProvider) {
        self.provider = provider
    }

    func reset() {
        networkSettings = nil
        // Capture the old generation now; a later queued cleanup must never
        // read and cancel a replacement registered in the meantime.
        let retired = takeMonitor()
        Self.monitorQueue.async { retired?.cancel() }
    }
}

// MARK: - LibboxPlatformInterface

extension AuroraPlatform: LibboxPlatformInterfaceProtocol {
    func openTun(_ options: (any LibboxTunOptionsProtocol)?, ret0_: UnsafeMutablePointer<Int32>?) throws {
        guard let provider else {
            throw AuroraError("provider released")
        }
        guard let options else {
            throw AuroraError("nil tun options")
        }
        guard let ret0_ else {
            throw AuroraError("nil return pointer")
        }
        let requestedMTU = options.getMTU()
        // Old saved NETunnelProvider profiles can outlive an app upgrade. A
        // pre-NetworkPolicy profile has no TUN mtu, so sing-box reports its
        // 4064-byte default here. That is unsafe on Internet VPN paths and can
        // make Chromium/Electron TLS records or images fail while small curl
        // probes still pass. Keep explicit Apple-safe values, otherwise fall
        // back to Aurora's compatibility baseline.
        let effectiveMTU: Int32 = (1280...1500).contains(requestedMTU)
            ? requestedMTU
            : 1400
        extDiag(
            "openTun: entered (autoRoute=\(options.getAutoRoute()) " +
            "requestedMTU=\(requestedMTU) effectiveMTU=\(effectiveMTU))"
        )

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        settings.mtu = NSNumber(value: effectiveMTU)

        // DNS: libbox reports a TUN-local resolver; actual split DNS happens inside sing-box.
        let dnsServer = try options.getDNSServerAddress()
        let dnsSettings = NEDNSSettings(servers: [dnsServer.value])

        // ---- IPv4 ----
        var ipv4Addresses: [String] = []
        var ipv4Masks: [String] = []
        let v4AddrIter = options.getInet4Address()!
        while v4AddrIter.hasNext() {
            let prefix = v4AddrIter.next()!
            ipv4Addresses.append(prefix.address())
            ipv4Masks.append(prefix.mask())
        }
        let ipv4Settings = NEIPv4Settings(addresses: ipv4Addresses, subnetMasks: ipv4Masks)

        var ipv4Routes: [NEIPv4Route] = []
        let v4RouteIter = options.getInet4RouteAddress()!
        if v4RouteIter.hasNext() {
            while v4RouteIter.hasNext() {
                let prefix = v4RouteIter.next()!
                ipv4Routes.append(NEIPv4Route(destinationAddress: prefix.address(), subnetMask: prefix.mask()))
            }
        } else {
            // auto_route with no explicit ranges → send everything through the tunnel.
            ipv4Routes.append(NEIPv4Route.default())
        }
        var ipv4ExcludeRoutes: [NEIPv4Route] = []
        let v4ExcludeIter = options.getInet4RouteExcludeAddress()!
        while v4ExcludeIter.hasNext() {
            let prefix = v4ExcludeIter.next()!
            ipv4ExcludeRoutes.append(NEIPv4Route(destinationAddress: prefix.address(), subnetMask: prefix.mask()))
        }
        ipv4Settings.includedRoutes = ipv4Routes
        ipv4Settings.excludedRoutes = ipv4ExcludeRoutes
        settings.ipv4Settings = ipv4Settings

        // ---- IPv6 ----
        var ipv6Addresses: [String] = []
        var ipv6Prefixes: [NSNumber] = []
        let v6AddrIter = options.getInet6Address()!
        while v6AddrIter.hasNext() {
            let prefix = v6AddrIter.next()!
            ipv6Addresses.append(prefix.address())
            ipv6Prefixes.append(NSNumber(value: prefix.prefix()))
        }
        if !ipv6Addresses.isEmpty {
            let ipv6Settings = NEIPv6Settings(addresses: ipv6Addresses, networkPrefixLengths: ipv6Prefixes)
            var ipv6Routes: [NEIPv6Route] = []
            let v6RouteIter = options.getInet6RouteAddress()!
            if v6RouteIter.hasNext() {
                while v6RouteIter.hasNext() {
                    let prefix = v6RouteIter.next()!
                    ipv6Routes.append(NEIPv6Route(destinationAddress: prefix.address(), networkPrefixLength: NSNumber(value: prefix.prefix())))
                }
            } else {
                ipv6Routes.append(NEIPv6Route.default())
            }
            var ipv6ExcludeRoutes: [NEIPv6Route] = []
            let v6ExcludeIter = options.getInet6RouteExcludeAddress()!
            while v6ExcludeIter.hasNext() {
                let prefix = v6ExcludeIter.next()!
                ipv6ExcludeRoutes.append(NEIPv6Route(destinationAddress: prefix.address(), networkPrefixLength: NSNumber(value: prefix.prefix())))
            }
            ipv6Settings.includedRoutes = ipv6Routes
            ipv6Settings.excludedRoutes = ipv6ExcludeRoutes
            settings.ipv6Settings = ipv6Settings
        }

        // If we are not capturing the whole default route, scope DNS to the tunnel only.
        let hasDefaultRoute = ipv4Routes.contains {
            $0.destinationAddress == "0.0.0.0" && $0.destinationSubnetMask == "0.0.0.0"
        }
        if !hasDefaultRoute {
            dnsSettings.matchDomains = [""]
            dnsSettings.matchDomainsNoSearch = true
        }
        settings.dnsSettings = dnsSettings

        networkSettings = settings

        // Apply settings synchronously, then hand libbox the TUN fd.
        extDiag("openTun: applying NEPacketTunnelNetworkSettings")
        let semaphore = DispatchSemaphore(value: 0)
        var applyError: Error?
        provider.setTunnelNetworkSettings(settings) { error in
            applyError = error
            semaphore.signal()
        }
        semaphore.wait()
        extDiag("openTun: settings applied (err=\(applyError?.localizedDescription ?? "none"))")
        if let applyError {
            throw applyError
        }

        // Preferred: pull the fd straight off the packetFlow's underlying socket.
        if let fd = provider.packetFlow.value(forKeyPath: "socket.fileDescriptor") as? Int32, fd != -1 {
            extDiag("openTun: returning packetFlow fd \(fd)")
            ret0_.pointee = fd
            return
        }
        // Fallback: libbox's own lookup of the tunnel fd in the process.
        let fdFromLoop = LibboxGetTunnelFileDescriptor()
        if fdFromLoop != -1 {
            extDiag("openTun: returning loop fd \(fdFromLoop)")
            ret0_.pointee = fdFromLoop
        } else {
            extDiag("openTun: NO fd available")
            throw AuroraError("could not obtain TUN file descriptor")
        }
    }

    func underNetworkExtension() -> Bool {
        true // tell sing-box it runs inside NE (affects memory strategy)
    }

    func includeAllNetworks() -> Bool {
        false
    }

    func usePlatformAutoDetectControl() -> Bool {
        // iOS NE lives outside the tunnel; let sing-box auto-detect via our monitor.
        false
    }

    func autoDetectControl(_ fd: Int32) throws {
        // No-op on iOS (no socket protect needed; the extension is outside the tunnel).
    }

    func useProcFS() -> Bool {
        false
    }

    // ---- default interface monitor (needed for auto_detect_interface) ----

    func startDefaultInterfaceMonitor(_ listener: (any LibboxInterfaceUpdateListenerProtocol)?) throws {
        extDiag("startDefaultInterfaceMonitor: entered")
        defer { extDiag("startDefaultInterfaceMonitor: returned") }
        guard let listener else { return }
        let session = InterfaceMonitorSession(listener)
        monitorLock.lock()
        let retired = interfaceMonitor
        interfaceMonitor = session
        monitorLock.unlock()
        Self.monitorQueue.async { [weak self] in
            retired?.cancel()
            guard let self, self.isCurrent(session) else {
                session.cancel()
                return
            }
            session.monitor.pathUpdateHandler = { [weak self, weak session] path in
                guard let self, let session, self.isCurrent(session) else { return }
                self.notify(session, path)
                if !session.startupFinished {
                    self.startReconcileTimer(session)
                    session.finishStartup()
                }
            }
            session.monitor.start(queue: Self.monitorQueue)
        }
        session.ready.wait()
        guard isCurrent(session) else {
            throw AuroraError("interface monitor closed during startup")
        }
    }

    func closeDefaultInterfaceMonitor(_ listener: (any LibboxInterfaceUpdateListenerProtocol)?) throws {
        let retired = takeMonitor(matching: listener)
        Self.monitorQueue.async { retired?.cancel() }
    }

    private func notify(_ session: InterfaceMonitorSession, _ path: Network.NWPath) {
        guard path.status != .unsatisfied, let iface = Self.physicalInterface(from: path) else {
            if session.lastReportedInterface != nil {
                extDiag("ifmon: default interface lost (path=\(path.status))")
            }
            session.lastReportedInterface = nil
            session.listener.updateDefaultInterface("", interfaceIndex: -1, isExpensive: false, isConstrained: false)
            return
        }
        let index = Int32(iface.index)
        if session.lastReportedInterface?.name != iface.name || session.lastReportedInterface?.index != index {
            extDiag("ifmon: default interface -> \(iface.name)#\(index) expensive=\(path.isExpensive)")
        }
        session.lastReportedInterface = (iface.name, index)
        session.listener.updateDefaultInterface(iface.name, interfaceIndex: index, isExpensive: path.isExpensive, isConstrained: path.isConstrained)
    }

    /// Never report the tunnel itself (ours or another VPN's) as the default
    /// interface: sing-box binds its outbound dials to whatever we report, and
    /// a tunnel-bound dial re-enters the TUN — an instant routing loop that
    /// reads as total blackhole while NE still says "connected".
    private static func physicalInterface(from path: Network.NWPath) -> NWInterface? {
        for iface in path.availableInterfaces {
            switch iface.type {
            case .wifi, .cellular, .wiredEthernet:
                return iface
            case .loopback:
                continue
            default:
                if !isTunnelLikeName(iface.name) { return iface }
            }
        }
        return nil
    }

    private static func isTunnelLikeName(_ name: String) -> Bool {
        name.hasPrefix("utun") || name.hasPrefix("tun") || name.hasPrefix("tap")
            || name.hasPrefix("ipsec") || name.hasPrefix("ppp")
            || name.hasPrefix("awdl") || name.hasPrefix("llw")
            || name.hasPrefix("lo")
    }

    /// NWPathMonitor callbacks can be missed or arrive with a stale snapshot
    /// around aggressive interface churn (hotspot 4G↔5G handovers, sleep/wake).
    /// A stale default interface wedges every future dial until the tunnel is
    /// restarted, so re-check the live path periodically and re-notify when the
    /// last delivered state no longer matches reality.
    private func startReconcileTimer(_ session: InterfaceMonitorSession) {
        session.timer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: Self.monitorQueue)
        timer.schedule(deadline: .now() + 15, repeating: 15)
        timer.setEventHandler { [weak self, weak session] in
            guard let self, let session, self.isCurrent(session) else { return }
            let path = session.monitor.currentPath
            var current: (name: String, index: Int32)?
            if path.status != .unsatisfied, let iface = Self.physicalInterface(from: path) {
                current = (iface.name, Int32(iface.index))
            }
            let last = session.lastReportedInterface
            let inSync = (current == nil && last == nil)
                || (current != nil && last != nil
                    && current!.name == last!.name && current!.index == last!.index)
            if !inSync {
                extDiag("ifmon: reconcile caught missed update; re-notifying")
                self.notify(session, path)
            }
        }
        timer.resume()
        session.timer = timer
    }

    func getInterfaces() throws -> any LibboxNetworkInterfaceIteratorProtocol {
        let path = currentMonitor()?.monitor.currentPath
        var interfaces: [LibboxNetworkInterface] = []
        if let path, path.status != .unsatisfied {
            for it in path.availableInterfaces {
                let iface = LibboxNetworkInterface()
                iface.name = it.name
                iface.index = Int32(it.index)
                switch it.type {
                case .wifi: iface.type = LibboxInterfaceTypeWIFI
                case .cellular: iface.type = LibboxInterfaceTypeCellular
                case .wiredEthernet: iface.type = LibboxInterfaceTypeEthernet
                default: iface.type = LibboxInterfaceTypeOther
                }
                interfaces.append(iface)
            }
        }
        return NetworkInterfaceIterator(interfaces)
    }

    // ---- unused-on-iOS-for-M2 platform hooks ----

    func findConnectionOwner(_ ipProtocol: Int32, sourceAddress: String?, sourcePort: Int32, destinationAddress: String?, destinationPort: Int32) throws -> LibboxConnectionOwner {
        throw AuroraError("findConnectionOwner not implemented")
    }

    func clearDNSCache() {
        guard let provider, let networkSettings else { return }
        let s1 = DispatchSemaphore(value: 0)
        provider.setTunnelNetworkSettings(nil) { _ in s1.signal() }
        s1.wait()
        let s2 = DispatchSemaphore(value: 0)
        provider.setTunnelNetworkSettings(networkSettings) { _ in s2.signal() }
        s2.wait()
    }

    func readWIFIState() -> LibboxWIFIState? {
        nil
    }

    func send(_ notification: LibboxNotification?) throws {
        // No user notifications in M2.
    }

    func systemCertificates() -> (any LibboxStringIteratorProtocol)? {
        nil
    }

    func localDNSTransport() -> (any LibboxLocalDNSTransportProtocol)? {
        nil
    }
}

// MARK: - LibboxCommandServerHandler

extension AuroraPlatform: LibboxCommandServerHandlerProtocol {
    func getSystemProxyStatus() throws -> LibboxSystemProxyStatus {
        LibboxSystemProxyStatus()
    }

    func serviceReload() throws {
        try provider?.reloadService()
    }

    func serviceStop() throws {
        // Tear down the NE session too, not just the core. Closing only the
        // core leaves NE owning the utun and the default route with nothing to
        // move packets — a total blackhole while NEVPNStatus stays .connected
        // and the UI shows "Connected".
        //
        // The core shutdown is bounded AND detached: this callback arrives on
        // libbox's own gRPC thread, so blocking it on sing-box's shutdown is
        // precisely how a stop becomes a 20-second hang. Cancelling the tunnel
        // makes NE call stopTunnel, which performs the authoritative release;
        // whichever path gets there first wins, and a second concurrent
        // CloseService is a no-op (sing-box guards it on service status).
        let provider = provider
        Task { await provider?.stopService() }
        provider?.cancelTunnelWithError(nil)
    }

    func setSystemProxyEnabled(_ isEnabled: Bool) throws {
        // Not supported on iOS.
    }

    func writeDebugMessage(_ message: String?) {
        guard let message else { return }
        NSLog("[aurora] %@", message)
    }
}

// MARK: - helpers

struct AuroraError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private final class NetworkInterfaceIterator: NSObject, LibboxNetworkInterfaceIteratorProtocol {
    private var iterator: IndexingIterator<[LibboxNetworkInterface]>
    private var current: LibboxNetworkInterface?
    init(_ array: [LibboxNetworkInterface]) {
        iterator = array.makeIterator()
    }

    func hasNext() -> Bool {
        current = iterator.next()
        return current != nil
    }

    func next() -> LibboxNetworkInterface? {
        current
    }
}
