import Foundation

enum ConfigError: LocalizedError {
    case noServers
    case badServer(String)
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .noServers: return "Нет серверов. Добавьте подписку или ссылку."
        case .badServer(let name): return "Не удалось разобрать сервер «\(name)»"
        case .invalid(let message): return "Ошибка конфигурации: \(message)"
        }
    }
}

enum BuildMode {
    case single(ServerNode)
    /// leastPing balancer over candidates, kept fresh by the observatory (HTTP GET probes).
    case auto([ServerNode])
}

struct BuildInput {
    var mode: BuildMode
    /// Servers that get a local HTTP test inbound so latency can be measured while connected.
    var testServers: [ServerNode]
    /// nil = routing disabled (everything through the proxy except LAN).
    var profile: RoutingProfile?
    var settings: EffectiveSettings
    var hasGeoIP: Bool
    var hasGeoSite: Bool
    var stripGeo: Bool
    var logPath: String
    var title: String
}

/// Collects outbounds, applies per-outbound tweaks (mux, fragmentation, core-side DNS resolution).
struct OutboundCollector {
    let settings: EffectiveSettings
    let resolveViaCore: Bool
    var outbounds: [JSONObject] = []
    var needsFragment = false
    var serverDomains: [String] = []
    var endpoints: [String: ServerEndpoint] = [:]
    private var dependencyCounter = 0

    init(settings: EffectiveSettings, resolveViaCore: Bool) {
        self.settings = settings
        self.resolveViaCore = resolveViaCore
    }

    mutating func add(_ server: ServerNode, tag: String, tweak: Bool = true) throws {
        guard var main = JSONUtil.object(server.outbound) else { throw ConfigError.badServer(server.name) }
        main["tag"] = tag
        var dependencies: [JSONObject] = []
        if let text = server.dependencies, let list = JSONUtil.any(text) as? [JSONObject], !list.isEmpty {
            var rename: [String: String] = [:]
            for dependency in list {
                if let original = dependency["tag"] as? String {
                    dependencyCounter += 1
                    rename[original] = "dep\(dependencyCounter)-\(original)"
                }
            }
            for var dependency in list {
                if let original = dependency["tag"] as? String, let renamed = rename[original] {
                    dependency["tag"] = renamed
                }
                Self.renameDialerProxy(&dependency, rename)
                dependencies.append(dependency)
            }
            Self.renameDialerProxy(&main, rename)
        }
        if tweak { apply(&main) }
        outbounds.append(main)
        outbounds.append(contentsOf: dependencies)
        if let endpoint = ShareLinks.endpoint(of: main) {
            endpoints[server.id.uuidString] = endpoint
            noteDomain(endpoint.host)
        }
        for dependency in dependencies {
            if let endpoint = ShareLinks.endpoint(of: dependency) { noteDomain(endpoint.host) }
        }
    }

    mutating func noteDomain(_ host: String) {
        guard !host.isEmpty, !ShareLinks.isIPAddress(host), !serverDomains.contains(host) else { return }
        serverDomains.append(host)
    }

    static func renameDialerProxy(_ outbound: inout JSONObject, _ rename: [String: String]) {
        guard var stream = outbound["streamSettings"] as? JSONObject,
              var sockopt = stream["sockopt"] as? JSONObject,
              let dialer = sockopt["dialerProxy"] as? String,
              let renamed = rename[dialer] else { return }
        sockopt["dialerProxy"] = renamed
        stream["sockopt"] = sockopt
        outbound["streamSettings"] = stream
    }

    private mutating func apply(_ outbound: inout JSONObject) {
        let proto = ((outbound["protocol"] as? String) ?? "").lowercased()
        var stream = outbound["streamSettings"] as? JSONObject ?? [:]
        let network = ((stream["network"] as? String) ?? "raw").lowercased()
        let security = ((stream["security"] as? String) ?? "none").lowercased()
        let flow = ((outbound["settings"] as? JSONObject)?["flow"] as? String) ?? ""
        var sockopt = stream["sockopt"] as? JSONObject ?? [:]
        let udpTransport = ["kcp", "mkcp", "quic", "hysteria"].contains(network)
            || ["hysteria", "hysteria2", "wireguard"].contains(proto)

        if settings.mux, outbound["mux"] == nil,
           ["vless", "vmess", "trojan", "shadowsocks"].contains(proto),
           flow.isEmpty, !udpTransport, !["xhttp", "splithttp"].contains(network) {
            outbound["mux"] = ["enabled": true, "concurrency": 8, "xudpConcurrency": 16, "xudpProxyUDP443": "reject"] as JSONObject
        }
        if settings.fragment.enabled, sockopt["dialerProxy"] == nil, !udpTransport,
           security == "tls" || security == "reality" {
            sockopt["dialerProxy"] = "fragment"
            needsFragment = true
        }
        if resolveViaCore, sockopt["domainStrategy"] == nil,
           let endpoint = ShareLinks.endpoint(of: outbound), !ShareLinks.isIPAddress(endpoint.host) {
            // Resolve the proxy host through Xray's DNS (pre-resolved hosts / direct domestic DNS),
            // never through the system resolver that points into the tunnel.
            sockopt["domainStrategy"] = settings.enableIPv6 ? "UseIP" : "UseIPv4"
        }
        if !sockopt.isEmpty { stream["sockopt"] = sockopt }
        if !stream.isEmpty { outbound["streamSettings"] = stream }
    }

    func fragmentOutbound() -> JSONObject {
        var fragment: JSONObject = [
            "packets": settings.fragment.packets.nonEmpty ?? "tlshello",
            "length": settings.fragment.length.nonEmpty ?? "100-200",
            "interval": settings.fragment.interval.nonEmpty ?? "10-20",
        ]
        if let maxSplit = settings.fragment.maxSplit.nonEmpty { fragment["maxSplit"] = maxSplit }
        var freedom: JSONObject = ["fragment": fragment]
        if resolveViaCore { freedom["targetStrategy"] = settings.enableIPv6 ? "UseIP" : "UseIPv4" }
        return ["tag": "fragment", "protocol": "freedom", "settings": freedom]
    }
}

enum ConfigBuilder {
    // MARK: Tunnel config

    static func tunnelPlan(_ input: BuildInput) throws -> TunnelPlan {
        let s = input.settings
        var collector = OutboundCollector(settings: s, resolveViaCore: true)
        var serverTag: [UUID: String] = [:]
        var tagNames: [String: String] = [:]
        var autoTags: [String] = []
        var balancers: [JSONObject] = []
        var observatory: JSONObject?
        var proxyTarget: JSONObject = ["outboundTag": "proxy"]
        var fullConfig: JSONObject?

        switch input.mode {
        case .single(let server):
            if let text = server.fullConfig, let config = JSONUtil.object(text) {
                fullConfig = config
                tagNames["proxy"] = server.name
            } else {
                try collector.add(server, tag: "proxy")
                serverTag[server.id] = "proxy"
                tagNames["proxy"] = server.name
            }
        case .auto(let candidates):
            for (index, server) in candidates.enumerated() {
                let tag = "auto-\(index)"
                do { try collector.add(server, tag: tag) } catch { continue }
                serverTag[server.id] = tag
                tagNames[tag] = server.name
                autoTags.append(tag)
            }
            guard let first = autoTags.first else { throw ConfigError.noServers }
            balancers = [[
                "tag": "balancer",
                "selector": ["auto-"],
                "strategy": ["type": "leastPing"],
                "fallbackTag": first,
            ]]
            observatory = [
                "subjectSelector": ["auto-"],
                "probeURL": s.testURL,
                "probeInterval": "\(max(1, s.autoProbeMinutes))m",
                "enableConcurrency": true,
            ]
            proxyTarget = ["balancerTag": "balancer"]
        }

        // Local HTTP inbounds that route straight to one server: used for Proxy GET tests while connected.
        var inbounds: [JSONObject] = [tunInbound(s)]
        var testRules: [JSONObject] = []
        var testInbounds: [String: UUID] = [:]
        for (index, server) in input.testServers.enumerated() {
            var tag = serverTag[server.id]
            if tag == nil {
                let newTag = "t-\(index)"
                if (try? collector.add(server, tag: newTag)) != nil {
                    tag = newTag
                    tagNames[newTag] = server.name
                }
            }
            guard let outboundTag = tag else { continue }
            let inboundTag = "ti-\(index)"
            inbounds.append(["tag": inboundTag, "listen": "127.0.0.1", "port": 0, "protocol": "http", "settings": emptyObject])
            testRules.append(["type": "field", "inboundTag": [inboundTag], "outboundTag": outboundTag])
            testInbounds[inboundTag] = server.id
        }

        let config: JSONObject
        if let base = fullConfig {
            config = wrapFullConfig(base, inbounds: inbounds, testRules: testRules, collector: &collector, input: input)
        } else {
            let dns = dnsSection(input: input, serverDomains: collector.serverDomains, proxyTarget: proxyTarget)
            var rules = testRules
            rules.append(["type": "field", "inboundTag": ["tun-in"], "port": "53", "outboundTag": "dns-out"])
            rules.append(contentsOf: dns.rules)
            rules.append(["type": "field", "ip": TunnelConstants.privateCIDRs, "outboundTag": "direct"])
            rules.append(contentsOf: profileRules(input: input, proxyTarget: proxyTarget))

            var outbounds = collector.outbounds
            outbounds.append(["tag": "direct", "protocol": "freedom",
                              "settings": ["targetStrategy": s.enableIPv6 ? "UseIP" : "UseIPv4"]])
            outbounds.append(["tag": "block", "protocol": "blackhole", "settings": emptyObject])
            outbounds.append(["tag": "dns-out", "protocol": "dns", "settings": emptyObject])
            if collector.needsFragment { outbounds.append(collector.fragmentOutbound()) }

            var routing: JSONObject = ["domainStrategy": domainStrategy(input), "rules": rules]
            if !balancers.isEmpty { routing["balancers"] = balancers }

            var built: JSONObject = [
                "log": logSection(input),
                "inbounds": inbounds,
                "outbounds": outbounds,
                "routing": routing,
                "dns": dns.dns,
                "stats": emptyObject,
                "policy": policySection(),
                "metrics": ["listen": "127.0.0.1:0"],
            ]
            if let observatory { built["observatory"] = observatory }
            config = built
        }

        let json = try JSONUtil.string(config)
        return TunnelPlan(
            configJSON: json,
            network: TunnelNetwork(mtu: s.mtu, excludeLAN: s.excludeLocalNetworks),
            title: input.title,
            isAuto: !autoTags.isEmpty,
            testInbounds: testInbounds,
            endpoints: collector.endpoints,
            tagNames: tagNames,
            autoTags: autoTags,
            serverDomains: collector.serverDomains,
            createdAt: Date())
    }

    /// Servers from JSON subscriptions keep their own routing/DNS ("works strictly by its source", as in Happ).
    /// Only the TUN inbound, DNS hijack, LAN bypass, stats and test inbounds are injected.
    private static func wrapFullConfig(_ base: JSONObject, inbounds: [JSONObject], testRules: [JSONObject],
                                       collector: inout OutboundCollector, input: BuildInput) -> JSONObject {
        var config = base
        var outbounds = config["outbounds"] as? [JSONObject] ?? []
        var tags = Set(outbounds.compactMap { $0["tag"] as? String })
        func uniqueTag(_ wanted: String) -> String {
            var tag = wanted
            var counter = 1
            while tags.contains(tag) { counter += 1; tag = "\(wanted)-\(counter)" }
            tags.insert(tag)
            return tag
        }
        for outbound in outbounds {
            let proto = ((outbound["protocol"] as? String) ?? "").lowercased()
            if !["freedom", "blackhole", "dns", "loopback"].contains(proto), let endpoint = ShareLinks.endpoint(of: outbound) {
                collector.noteDomain(endpoint.host)
            }
        }
        let existingDNS = outbounds.first(where: { (($0["protocol"] as? String) ?? "").lowercased() == "dns" })
        var dnsTag = existingDNS?["tag"] as? String
        if dnsTag == nil {
            let tag = uniqueTag("dns-out")
            outbounds.append(["tag": tag, "protocol": "dns", "settings": emptyObject])
            dnsTag = tag
        }
        let existingDirect = outbounds.first(where: { outbound in
            guard (outbound["protocol"] as? String)?.lowercased() == "freedom" else { return false }
            let settings = outbound["settings"] as? JSONObject ?? [:]
            return settings["fragment"] == nil && settings["redirect"] == nil && settings["noises"] == nil
        })
        var directTag = existingDirect?["tag"] as? String
        if directTag == nil {
            let tag = uniqueTag("direct")
            outbounds.append(["tag": tag, "protocol": "freedom", "settings": emptyObject])
            directTag = tag
        }
        let baseTags = tags
        for outbound in collector.outbounds where !baseTags.contains((outbound["tag"] as? String) ?? "") {
            outbounds.append(outbound)
        }
        if collector.needsFragment, !tags.contains("fragment") { outbounds.append(collector.fragmentOutbound()) }
        config["outbounds"] = outbounds
        config["inbounds"] = inbounds

        var routing = config["routing"] as? JSONObject ?? [:]
        let baseRules = routing["rules"] as? [JSONObject] ?? []
        var rules = testRules
        rules.append(["type": "field", "inboundTag": ["tun-in"], "port": "53", "outboundTag": dnsTag ?? "dns-out"])
        rules.append(["type": "field", "ip": TunnelConstants.privateCIDRs, "outboundTag": directTag ?? "direct"])
        routing["rules"] = rules + baseRules
        config["routing"] = routing

        if config["dns"] == nil {
            config["dns"] = [
                "servers": ["https://cloudflare-dns.com/dns-query", "1.1.1.1"],
                "hosts": ["cloudflare-dns.com": ["1.1.1.1", "1.0.0.1"]],
                "queryStrategy": input.settings.enableIPv6 ? "UseIP" : "UseIPv4",
            ] as JSONObject
        }
        config["log"] = logSection(input)
        config["stats"] = emptyObject
        config["policy"] = policySection()
        config["metrics"] = ["listen": "127.0.0.1:0"]
        config.removeValue(forKey: "api")
        return config
    }

    // MARK: Sections

    private static func tunInbound(_ s: EffectiveSettings) -> JSONObject {
        [
            "tag": "tun-in",
            "port": 0,
            "protocol": "tun",
            "settings": ["name": "utun99", "mtu": s.mtu] as JSONObject,
            "sniffing": [
                "enabled": s.sniffing,
                "destOverride": ["http", "tls", "quic"],
                "routeOnly": true,
            ] as JSONObject,
        ]
    }

    private static func logSection(_ input: BuildInput) -> JSONObject {
        ["loglevel": input.settings.logLevel, "error": input.logPath, "access": "none", "dnsLog": false]
    }

    private static func policySection() -> JSONObject {
        [
            "levels": ["0": ["handshake": 6, "connIdle": 300, "uplinkOnly": 2, "downlinkOnly": 5] as JSONObject] as JSONObject,
            "system": [
                "statsInboundUplink": true,
                "statsInboundDownlink": true,
                "statsOutboundUplink": true,
                "statsOutboundDownlink": true,
            ] as JSONObject,
        ]
    }

    private static func domainStrategy(_ input: BuildInput) -> String {
        guard let profile = input.profile else { return "AsIs" }
        let allowed = ["AsIs", "IPIfNonMatch", "IPOnDemand"]
        return allowed.first { $0.lowercased() == profile.domainStrategy.lowercased() } ?? "IPIfNonMatch"
    }

    private static func merge(_ rule: JSONObject, _ target: JSONObject) -> JSONObject {
        rule.merging(target) { _, new in new }
    }

    static func filterDomains(_ list: [String], input: BuildInput) -> [String] {
        list.compactMap { raw in
            let entry = raw.trimmed
            let lower = entry.lowercased()
            if entry.isEmpty || entry.hasPrefix("#") { return nil }
            if lower.hasPrefix("geosite:"), !input.hasGeoSite || input.stripGeo { return nil }
            if lower.hasPrefix("ext:"), input.stripGeo { return nil }
            return entry
        }
    }

    static func filterIPs(_ list: [String], input: BuildInput) -> [String] {
        list.compactMap { raw in
            let entry = raw.trimmed
            let lower = entry.lowercased()
            if entry.isEmpty || entry.hasPrefix("#") { return nil }
            if lower.hasPrefix("geoip:"), !input.hasGeoIP || input.stripGeo { return nil }
            if lower.hasPrefix("ext:"), input.stripGeo { return nil }
            return entry
        }
    }

    /// block → proxy → direct → default (proxy if GlobalProxy, else direct).
    private static func profileRules(input: BuildInput, proxyTarget: JSONObject) -> [JSONObject] {
        var rules: [JSONObject] = []
        guard let profile = input.profile else {
            rules.append(merge(["type": "field", "network": "tcp,udp"], proxyTarget))
            return rules
        }
        let direct: JSONObject = ["outboundTag": "direct"]
        let block: JSONObject = ["outboundTag": "block"]
        func add(_ key: String, _ values: [String], _ target: JSONObject) {
            guard !values.isEmpty else { return }
            rules.append(merge(["type": "field", key: values], target))
        }
        add("domain", filterDomains(profile.blockSites, input: input), block)
        add("ip", filterIPs(profile.blockIP, input: input), block)
        add("domain", filterDomains(profile.proxySites, input: input), proxyTarget)
        add("ip", filterIPs(profile.proxyIP, input: input), proxyTarget)
        add("domain", filterDomains(profile.directSites, input: input), direct)
        add("ip", filterIPs(profile.directIP, input: input), direct)
        rules.append(merge(["type": "field", "network": "tcp,udp"], profile.globalProxy ? proxyTarget : direct))
        return rules
    }

    private struct DNSServerSpec {
        var address: String
        var host: String?
        var ip: String?
    }

    private static func dnsServer(type: String, domain: String, ip: String, hosts: inout JSONObject) -> DNSServerSpec {
        if type.lowercased() == "doh", let url = URL(string: domain), let host = url.host, !host.isEmpty {
            if ShareLinks.isIPAddress(host) { return DNSServerSpec(address: domain, host: nil, ip: host) }
            let pinned = ip.nonEmpty ?? (hosts[host] as? String)
            if let pinned, hosts[host] == nil { hosts[host] = pinned }
            return DNSServerSpec(address: domain, host: host, ip: pinned)
        }
        let address = ip.nonEmpty ?? "1.1.1.1"
        return DNSServerSpec(address: address, host: nil, ip: address)
    }

    /// Remote DNS goes through the proxy; domestic DNS goes direct and serves "direct" domains
    /// (or everything in "blocked only" mode). Proxy hostnames are always resolved via domestic DNS.
    private static func dnsSection(input: BuildInput, serverDomains: [String], proxyTarget: JSONObject)
        -> (dns: JSONObject, rules: [JSONObject]) {
        let profile = input.profile ?? RoutingPresets.global
        var hosts: JSONObject = [:]
        for (domain, address) in profile.dnsHosts { hosts[domain] = address }
        let remote = dnsServer(type: profile.remoteDNSType, domain: profile.remoteDNSDomain, ip: profile.remoteDNSIP, hosts: &hosts)
        let domestic = dnsServer(type: profile.domesticDNSType, domain: profile.domesticDNSDomain, ip: profile.domesticDNSIP, hosts: &hosts)
        let serverEntries = serverDomains.map { "full:\($0)" }

        var servers: [Any] = []
        if input.profile == nil || profile.globalProxy {
            servers.append(remote.address)
            let directDomains = (input.profile == nil ? [] : filterDomains(profile.directSites, input: input)) + serverEntries
            if !directDomains.isEmpty {
                servers.append(["address": domestic.address, "domains": directDomains, "skipFallback": true] as JSONObject)
            }
        } else {
            servers.append(domestic.address)
            let proxyDomains = filterDomains(profile.proxySites, input: input)
            if !proxyDomains.isEmpty {
                servers.append(["address": remote.address, "domains": proxyDomains, "skipFallback": true] as JSONObject)
            }
        }

        var dns: JSONObject = [
            "tag": "dns-internal",
            "servers": servers,
            "queryStrategy": input.settings.enableIPv6 ? "UseIP" : "UseIPv4",
        ]
        if !hosts.isEmpty { dns["hosts"] = hosts }

        var rules: [JSONObject] = []
        if let host = domestic.host {
            rules.append(["type": "field", "inboundTag": ["dns-internal"], "domain": ["full:\(host)"], "outboundTag": "direct"])
        }
        if let ip = domestic.ip {
            rules.append(["type": "field", "inboundTag": ["dns-internal"], "ip": [ip], "outboundTag": "direct"])
        }
        rules.append(merge(["type": "field", "inboundTag": ["dns-internal"]], proxyTarget))
        return (dns, rules)
    }

    // MARK: Latency test config (runs inside the app while the VPN is off)

    static func testConfig(servers: [ServerNode], settings: EffectiveSettings) -> (json: String, inbounds: [String: UUID])? {
        var plain = settings
        plain.mux = false
        var collector = OutboundCollector(settings: plain, resolveViaCore: false)
        var inbounds: [JSONObject] = []
        var rules: [JSONObject] = []
        var map: [String: UUID] = [:]
        for (index, server) in servers.enumerated() {
            let tag = "t-\(index)"
            do { try collector.add(server, tag: tag) } catch { continue }
            let inboundTag = "ti-\(index)"
            inbounds.append(["tag": inboundTag, "listen": "127.0.0.1", "port": 0, "protocol": "http", "settings": emptyObject])
            rules.append(["type": "field", "inboundTag": [inboundTag], "outboundTag": tag])
            map[inboundTag] = server.id
        }
        guard !map.isEmpty else { return nil }
        var outbounds = collector.outbounds
        if collector.needsFragment { outbounds.append(collector.fragmentOutbound()) }
        outbounds.append(["tag": "direct", "protocol": "freedom", "settings": emptyObject])
        let config: JSONObject = [
            "log": ["loglevel": "none"],
            "inbounds": inbounds,
            "outbounds": outbounds,
            "routing": ["domainStrategy": "AsIs", "rules": rules] as JSONObject,
        ]
        guard let json = try? JSONUtil.string(config) else { return nil }
        return (json, map)
    }
}

struct FinalizedConfig {
    var json: String
    /// Inbound tag → local port.
    var testPorts: [String: Int]
    var metricsPort: Int?
}

enum ConfigFinalizer {
    /// Assigns free local ports, the TUN file descriptor, the geo asset path and pre-resolved hosts.
    static func finalize(configJSON: String, tunFD: Int32?, assetDir: String, hosts: [String: [String]],
                         logPath: String? = nil) throws -> FinalizedConfig {
        guard var config = JSONUtil.object(configJSON) else { throw ConfigError.invalid("JSON") }
        // The log file must live in a container this process can write to.
        if let logPath, var log = config["log"] as? JSONObject, log["error"] != nil {
            log["error"] = logPath
            config["log"] = log
        }
        var inbounds = config["inbounds"] as? [JSONObject] ?? []
        let testIndexes = inbounds.indices.filter { ((inbounds[$0]["tag"] as? String) ?? "").hasPrefix("ti-") }
        var metrics = config["metrics"] as? JSONObject
        let ports = try XrayCore.freePorts(testIndexes.count + (metrics == nil ? 0 : 1))
        var testPorts: [String: Int] = [:]
        for (offset, index) in testIndexes.enumerated() {
            inbounds[index]["port"] = ports[offset]
            if let tag = inbounds[index]["tag"] as? String { testPorts[tag] = ports[offset] }
        }
        config["inbounds"] = inbounds
        var metricsPort: Int?
        if metrics != nil, let port = ports.last {
            metrics?["listen"] = "127.0.0.1:\(port)"
            config["metrics"] = metrics
            metricsPort = port
        }

        var env = config["env"] as? [String: Any] ?? [:]
        env["xray.location.asset"] = assetDir
        if let tunFD { env["xray.tun.fd"] = String(tunFD) }
        config["env"] = env

        if !hosts.isEmpty {
            var dns = config["dns"] as? JSONObject ?? [:]
            var existing = dns["hosts"] as? JSONObject ?? [:]
            for (domain, addresses) in hosts where existing[domain] == nil && !addresses.isEmpty {
                existing[domain] = addresses
            }
            dns["hosts"] = existing
            config["dns"] = dns
        }
        return FinalizedConfig(json: try JSONUtil.string(config), testPorts: testPorts, metricsPort: metricsPort)
    }

    /// Copy for `testXray` inside the app: TUN replaced by SOCKS, no listeners, no log file.
    static func validationCopy(_ configJSON: String, assetDir: String) throws -> String {
        guard var config = JSONUtil.object(configJSON) else { throw ConfigError.invalid("JSON") }
        var inbounds = config["inbounds"] as? [JSONObject] ?? []
        for index in inbounds.indices {
            if ((inbounds[index]["protocol"] as? String) ?? "").lowercased() == "tun" {
                var socks: JSONObject = [
                    "tag": (inbounds[index]["tag"] as? String) ?? "tun-in",
                    "listen": "127.0.0.1",
                    "port": 10808,
                    "protocol": "socks",
                    "settings": ["udp": true] as JSONObject,
                ]
                if let sniffing = inbounds[index]["sniffing"] { socks["sniffing"] = sniffing }
                inbounds[index] = socks
            } else if JSONUtil.int(inbounds[index]["port"]) == 0 {
                inbounds[index]["port"] = 20000 + index
            }
        }
        config["inbounds"] = inbounds
        config.removeValue(forKey: "metrics")
        config["log"] = ["loglevel": "none"]
        var env = config["env"] as? [String: Any] ?? [:]
        env["xray.location.asset"] = assetDir
        config["env"] = env
        return try JSONUtil.string(config)
    }
}
