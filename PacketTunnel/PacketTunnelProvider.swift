import Foundation
import NetworkExtension

/// Packet tunnel: Xray-core reads/writes the utun file descriptor directly (Xray TUN inbound,
/// `xray.tun.fd`), so there is a single Go runtime and no tun2socks layer.
final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let queue = DispatchQueue(label: "strela.tunnel")
    private var plan: TunnelPlan?
    private var finalized: FinalizedConfig?
    private var resolvedHosts: [String: [String]] = [:]
    private var startedAt = Date()

    enum TunnelError: LocalizedError {
        case noPlan
        case noTunFD
        case core(String)

        var errorDescription: String? {
            switch self {
            case .noPlan: return "Нет конфигурации. Откройте приложение и подключитесь оттуда."
            case .noTunFD: return "Не удалось получить дескриптор utun"
            case .core(let message): return "Xray: \(message)"
            }
        }
    }

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        Store.writeTunnelError(nil)
        Store.truncateIfNeeded(Store.xrayLogURL, limit: 1024 * 1024)
        // The plan comes with the start request; providerConfiguration and the App Group file are
        // fallbacks (VPN on demand). This keeps working when a re-signer (GBox, ESign) drops App Groups.
        guard let plan = Self.plan(fromOptions: options) ?? storedPlan() else {
            fail(TunnelError.noPlan, completionHandler)
            return
        }
        AppLog.write("Запуск туннеля: \(plan.title) (App Group: \(AppGroup.isAvailable ? "есть" : "нет"))")
        queue.async {
            // Resolve proxy hostnames before our DNS settings take over the system resolver.
            let hosts = HostResolver.resolve(plan.serverDomains, timeout: 4)
            self.resolvedHosts = hosts
            self.setTunnelNetworkSettings(Self.networkSettings(plan.network)) { error in
                if let error {
                    self.fail(error, completionHandler)
                    return
                }
                self.queue.async {
                    do {
                        try self.startCore(plan)
                        self.startedAt = Date()
                        AppLog.write("Туннель запущен")
                        completionHandler(nil)
                    } catch {
                        self.fail(error, completionHandler)
                    }
                }
            }
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        AppLog.write("Остановка туннеля, причина: \(reason.rawValue)")
        queue.async {
            XrayCore.stop()
            completionHandler()
        }
    }

    override func sleep(completionHandler: @escaping () -> Void) {
        completionHandler()
    }

    override func wake() {}

    private func fail(_ error: Error, _ completionHandler: (Error?) -> Void) {
        let message = error.localizedDescription
        AppLog.write("Ошибка туннеля: \(message)")
        Store.writeTunnelError(message)
        XrayCore.stop()
        completionHandler(error)
    }

    private func startCore(_ plan: TunnelPlan) throws {
        guard let fd = Self.tunnelFileDescriptor() else { throw TunnelError.noTunFD }
        var candidates = [plan.configJSON]
        if let fallback = plan.fallbackConfigJSON, fallback != plan.configJSON { candidates.append(fallback) }
        var lastError: Error = TunnelError.noPlan
        for (index, configJSON) in candidates.enumerated() {
            do {
                let config = try ConfigFinalizer.finalize(
                    configJSON: configJSON,
                    tunFD: fd,
                    assetDir: Store.geoDir.path,
                    hosts: resolvedHosts,
                    logPath: Store.xrayLogURL.path)
                XrayCore.stop()
                try XrayCore.run(configJSON: config.json)
                if index > 0 { AppLog.write("Запущено без geoip/geosite (гео-файлы недоступны расширению)") }
                self.plan = plan
                self.finalized = config
                return
            } catch {
                AppLog.write("Xray не запустился: \(error.localizedDescription)")
                lastError = TunnelError.core(error.localizedDescription)
            }
        }
        throw lastError
    }

    private func storedPlan() -> TunnelPlan? {
        if let configuration = (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration,
           let data = configuration["plan"] as? Data,
           let plan = try? Store.makeDecoder().decode(TunnelPlan.self, from: data) {
            return plan
        }
        return Store.loadPlan()
    }

    private static func plan(fromOptions options: [String: NSObject]?) -> TunnelPlan? {
        guard let data = options?["plan"] as? Data else { return nil }
        return try? Store.makeDecoder().decode(TunnelPlan.self, from: data)
    }

    /// Swaps the Xray config without tearing the tunnel down (server switch, routing change).
    private func reload(with incoming: TunnelPlan?) throws {
        guard let newPlan = incoming ?? Store.loadPlan() else { throw TunnelError.noPlan }
        let missing = newPlan.serverDomains.filter { resolvedHosts[$0] == nil }
        if !missing.isEmpty {
            for (host, addresses) in HostResolver.resolve(missing, timeout: 3) { resolvedHosts[host] = addresses }
        }
        AppLog.write("Перезагрузка конфигурации: \(newPlan.title)")
        try startCore(newPlan)
    }

    // MARK: App messages

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        guard let request = try? JSONDecoder().decode(IPCRequest.self, from: messageData) else {
            completionHandler?(nil)
            return
        }
        switch request.command {
        case .status:
            Task {
                let status = await self.currentStatus()
                completionHandler?(try? Store.makeEncoder().encode(status))
            }
        case .ping:
            guard let ping = request.ping else {
                completionHandler?(nil)
                return
            }
            Task {
                let response = await self.runPing(ping)
                completionHandler?(try? JSONEncoder().encode(response))
            }
        case .reload:
            queue.async {
                do {
                    try self.reload(with: request.plan)
                    completionHandler?(Data("ok".utf8))
                } catch {
                    Store.writeTunnelError(error.localizedDescription)
                    completionHandler?(Data("error: \(error.localizedDescription)".utf8))
                }
            }
        case .speed:
            guard let speed = request.speed else {
                completionHandler?(nil)
                return
            }
            Task {
                let response = await self.runSpeed(speed)
                completionHandler?(try? JSONEncoder().encode(response))
            }
        case .logs:
            let xray = Store.tail(of: Store.xrayLogURL, maxBytes: 64 * 1024)
            let app = Store.tail(of: Store.appLogURL, maxBytes: 32 * 1024)
            completionHandler?(try? JSONEncoder().encode(["xray": xray, "app": app]))
        }
    }

    private func snapshot() -> (TunnelPlan?, FinalizedConfig?) {
        queue.sync { (plan, finalized) }
    }

    private func currentStatus() async -> TunnelStatus {
        let (plan, finalized) = snapshot()
        var status = TunnelStatus()
        status.title = plan?.title ?? ""
        status.autoTags = plan?.autoTags ?? []
        status.tagNames = plan?.tagNames ?? [:]
        status.priorityAuto = plan?.priorityAuto ?? false
        if let port = finalized?.metricsPort, let url = URL(string: "http://127.0.0.1:\(port)/debug/vars") {
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 2)
            request.httpMethod = "GET"
            if let (data, _) = try? await URLSession.shared.data(for: request) {
                status.applyMetrics(data)
            }
        }
        return status
    }

    private func runPing(_ request: PingRequest) async -> PingResponse {
        let (plan, finalized) = snapshot()
        guard let plan, let finalized else { return PingResponse(results: [:]) }
        let wanted = Set(request.serverIDs)
        let timeout = TimeInterval(max(2, request.timeout))
        let concurrency = min(max(1, request.concurrency), 4)
        var results: [UUID: Int] = [:]
        if request.type == .tcp {
            let jobs = request.serverIDs.compactMap { id -> LatencyTester.TCPJob? in
                guard let endpoint = plan.endpoints[id.uuidString] else { return nil }
                return LatencyTester.TCPJob(id: id, host: endpoint.host, port: endpoint.port)
            }
            results = await LatencyTester.tcpBatch(jobs, timeout: timeout, concurrency: concurrency)
        } else if let url = URL(string: request.url) {
            var jobs: [LatencyTester.HTTPJob] = []
            for (tag, id) in plan.testInbounds where wanted.contains(id) {
                if let port = finalized.testPorts[tag] { jobs.append(LatencyTester.HTTPJob(id: id, port: port)) }
            }
            results = await LatencyTester.httpBatch(jobs, url: url, method: request.type.httpMethod,
                                                    timeout: timeout, concurrency: concurrency)
        }
        var response: [String: Int] = [:]
        for (id, value) in results { response[id.uuidString] = value }
        return PingResponse(results: response)
    }

    /// Download speed through each requested server, one after another (via local test inbounds).
    private func runSpeed(_ request: SpeedRequest) async -> SpeedResponse {
        let (plan, finalized) = snapshot()
        guard let plan, let finalized, let url = URL(string: request.url) else { return SpeedResponse(results: [:]) }
        var jobs: [LatencyTester.HTTPJob] = []
        for id in request.serverIDs {
            guard let tag = plan.testInbounds.first(where: { $0.value == id })?.key,
                  let port = finalized.testPorts[tag] else { continue }
            jobs.append(LatencyTester.HTTPJob(id: id, port: port))
        }
        let results = await LatencyTester.throughputSequential(
            jobs, url: url, seconds: TimeInterval(max(2, request.seconds)), connectTimeout: 10)
        var response: [String: Double] = [:]
        for (id, value) in results { response[id.uuidString] = value }
        return SpeedResponse(results: response)
    }

    // MARK: Helpers

    static func networkSettings(_ network: TunnelNetwork) -> NEPacketTunnelNetworkSettings {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        settings.mtu = NSNumber(value: network.mtu)

        let ipv4 = NEIPv4Settings(addresses: [TunnelConstants.ipv4Address], subnetMasks: [TunnelConstants.ipv4Mask])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        if network.excludeLAN {
            ipv4.excludedRoutes = TunnelConstants.lanIPv4.map { NEIPv4Route(destinationAddress: $0.0, subnetMask: $0.1) }
        }
        settings.ipv4Settings = ipv4

        // IPv6 is always captured so it cannot leak around the tunnel; Xray DNS returns only A records
        // unless IPv6 is enabled in settings.
        let ipv6 = NEIPv6Settings(addresses: [TunnelConstants.ipv6Address],
                                  networkPrefixLengths: [NSNumber(value: TunnelConstants.ipv6Prefix)])
        ipv6.includedRoutes = [NEIPv6Route.default()]
        if network.excludeLAN {
            ipv6.excludedRoutes = [
                NEIPv6Route(destinationAddress: "fc00::", networkPrefixLength: 7),
                NEIPv6Route(destinationAddress: "fe80::", networkPrefixLength: 10),
            ]
        }
        settings.ipv6Settings = ipv6

        let dns = NEDNSSettings(servers: [TunnelConstants.dnsServer])
        dns.matchDomains = [""]
        settings.dnsSettings = dns
        return settings
    }

    /// The utun socket NetworkExtension created for us (same lookup as in Xray's iOS docs).
    static func tunnelFileDescriptor() -> Int32? {
        var buffer = [CChar](repeating: 0, count: 16) // IFNAMSIZ
        let prefix = Array("utun".utf8CString.dropLast())
        for fd: Int32 in 0...1024 {
            var length = socklen_t(buffer.count)
            // SYSPROTO_CONTROL = 2, UTUN_OPT_IFNAME = 2
            if getsockopt(fd, 2, 2, &buffer, &length) == 0, buffer.starts(with: prefix) {
                return fd
            }
        }
        return nil
    }
}

/// getaddrinfo-based resolver with an overall timeout.
enum HostResolver {
    static func resolve(_ hosts: [String], timeout: TimeInterval) -> [String: [String]] {
        guard !hosts.isEmpty else { return [:] }
        let results = LockedDictionary<String, [String]>()
        let group = DispatchGroup()
        for host in hosts {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let addresses = resolveOne(host)
                if !addresses.isEmpty { results[host] = addresses }
                group.leave()
            }
        }
        _ = group.wait(timeout: .now() + timeout)
        return results.snapshot
    }

    private static func resolveOne(_ host: String) -> [String] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &list) == 0, let first = list else { return [] }
        defer { freeaddrinfo(first) }
        var addresses: [String] = []
        var pointer: UnsafeMutablePointer<addrinfo>? = first
        while let info = pointer {
            var buffer = [CChar](repeating: 0, count: 1025) // NI_MAXHOST
            if getnameinfo(info.pointee.ai_addr, info.pointee.ai_addrlen, &buffer, socklen_t(buffer.count),
                           nil, 0, NI_NUMERICHOST) == 0 {
                let address = String(cString: buffer)
                if !addresses.contains(address) { addresses.append(address) }
            }
            pointer = info.pointee.ai_next
        }
        // IPv4 first: the core uses UseIPv4 unless IPv6 is enabled.
        return addresses.sorted { !$0.contains(":") && $1.contains(":") }
    }
}
