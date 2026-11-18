import Foundation

// MARK: - Groups & selection

enum ServerGroup {
    /// Group for servers added by hand (links, QR, JSON), not from a subscription.
    static let manualID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
}

enum ServerSelection: Codable, Hashable {
    case none
    case server(UUID)
    /// Automatic choice of the fastest server (Proxy GET) inside a group.
    case auto(UUID)
}

// MARK: - Latency

enum PingType: String, Codable, CaseIterable, Identifiable {
    case proxyGET = "proxy"
    case proxyHEAD = "proxy-head"
    case tcp = "tcp"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .proxyGET: return "Proxy GET"
        case .proxyHEAD: return "Proxy HEAD"
        case .tcp: return "TCP"
        }
    }

    var httpMethod: String { self == .proxyHEAD ? "HEAD" : "GET" }

    /// Values used by Happ's `ping-type` subscription parameter.
    init?(happValue: String) {
        switch happValue.lowercased() {
        case "proxy", "proxy-get", "get": self = .proxyGET
        case "proxy-head", "head": self = .proxyHEAD
        case "tcp", "icmp": self = .tcp
        default: return nil
        }
    }
}

enum ServerSortOrder: String, Codable, CaseIterable, Identifiable {
    case none = "without"
    case ping = "ping"
    case alphabet = "alphabet"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "Как в подписке"
        case .ping: return "По задержке"
        case .alphabet: return "По алфавиту"
        }
    }
}

struct FragmentSettings: Codable, Hashable {
    var enabled = false
    var packets = "tlshello"
    var length = "100-200"
    var interval = "10-20"
    var maxSplit = ""
}

// MARK: - Subscriptions

struct SubscriptionUserInfo: Codable, Hashable {
    var upload: Int64 = 0
    var download: Int64 = 0
    var total: Int64 = 0
    var expire: Date?

    var used: Int64 { upload + download }

    var daysLeft: Int? {
        guard let expire else { return nil }
        return Calendar.current.dateComponents([.day], from: Date(), to: expire).day
    }
}

/// Provider-controlled parameters (Happ-compatible headers / `#key: value` body lines).
struct ProviderOptions: Codable, Hashable {
    var pingType: PingType?
    var checkURL: String?
    var pingTimeout: Int?
    var autoConnect: Bool?
    var autoConnectType: String?
    var pingOnOpen: Bool?
    var autoUpdate: Bool?
    var autoUpdateOnOpen: Bool?
    var fragmentation: Bool?
    var fragmentPackets: String?
    var fragmentLength: String?
    var fragmentInterval: String?
    var fragmentMaxSplit: String?
    var sniffing: Bool?
    var mux: Bool?
    var hideSettings: Bool?
    var sortOrder: ServerSortOrder?
    var userAgent: String?
    var mtu: Int?
    var includeAllNetworks: Bool?
    var excludeLocalNetworks: Bool?
    var excludeAPNs: Bool?
}

struct ProxySubscription: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var url: String
    var fallbackURL: String?
    var lastUpdated: Date?
    var updateIntervalHours: Int?
    var userInfo: SubscriptionUserInfo?
    var supportURL: String?
    var webPageURL: String?
    var announce: String?
    var lastError: String?
    var autoUpdate = true
    var options = ProviderOptions()
    var isJSON = false
    var nameLocked = false

    var isDue: Bool {
        guard autoUpdate, options.autoUpdate != false else { return false }
        guard let lastUpdated else { return true }
        let hours = max(1, updateIntervalHours ?? 12)
        return Date().timeIntervalSince(lastUpdated) > Double(hours) * 3600
    }
}

// MARK: - Servers

struct ServerEndpoint: Codable, Hashable {
    var host: String
    var port: Int
}

struct ServerNode: Codable, Identifiable, Hashable {
    var id = UUID()
    var groupID: UUID
    var name: String
    /// Provider description (Happ `serverDescription`), shown instead of the protocol caption.
    var detail: String?
    /// Main Xray outbound as JSON text. Its tag is replaced when a config is built.
    var outbound: String
    /// JSON array of outbounds the main one depends on (`sockopt.dialerProxy`).
    var dependencies: String?
    /// Complete Xray config for servers from JSON subscriptions.
    var fullConfig: String?
    var link: String?
    var proto: String
    var address: String
    var port: Int
    var network: String
    var security: String
    /// Milliseconds; -1 means the test failed.
    var latency: Int?
    var testedAt: Date?

    var identityKey: String { link ?? outbound }

    var subtitle: String {
        if let detail, !detail.isEmpty { return detail }
        var parts = [Self.protocolTitle(proto)]
        switch security.lowercased() {
        case "reality": parts.append("Reality")
        case "tls": parts.append("TLS")
        default: break
        }
        if !network.isEmpty, network != "raw", network != "tcp" { parts.append(network.uppercased()) }
        return parts.joined(separator: " · ")
    }

    static func protocolTitle(_ proto: String) -> String {
        switch proto.lowercased() {
        case "vless": return "VLESS"
        case "vmess": return "VMess"
        case "trojan": return "Trojan"
        case "shadowsocks": return "Shadowsocks"
        case "socks": return "SOCKS"
        case "http": return "HTTP"
        case "hysteria", "hysteria2": return "Hysteria2"
        case "wireguard": return "WireGuard"
        default: return proto.uppercased()
        }
    }
}

// MARK: - Routing

enum GeoDefaults {
    static let geoip = "https://raw.githubusercontent.com/runetfreedom/russia-v2ray-rules-dat/release/geoip.dat"
    static let geosite = "https://raw.githubusercontent.com/runetfreedom/russia-v2ray-rules-dat/release/geosite.dat"
}

/// Routing profile. Field set mirrors Happ's routing JSON (happ://routing/...).
struct RoutingProfile: Codable, Identifiable, Hashable {
    var name: String
    var globalProxy = true
    var remoteDNSType = "DoH"
    var remoteDNSDomain = "https://cloudflare-dns.com/dns-query"
    var remoteDNSIP = "1.1.1.1"
    var domesticDNSType = "DoU"
    var domesticDNSDomain = ""
    var domesticDNSIP = "77.88.8.8"
    var geoipURL = GeoDefaults.geoip
    var geositeURL = GeoDefaults.geosite
    var dnsHosts: [String: String] = [:]
    var directSites: [String] = []
    var directIP: [String] = []
    var proxySites: [String] = []
    var proxyIP: [String] = []
    var blockSites: [String] = []
    var blockIP: [String] = []
    var domainStrategy = "IPIfNonMatch"
    var isBuiltIn = false
    var subscriptionID: UUID?

    var id: String { name }

    init(name: String) {
        self.name = name
    }

    var allEntries: [String] { directSites + directIP + proxySites + proxyIP + blockSites + blockIP }

    var needsGeo: Bool {
        allEntries.contains { $0.lowercased().hasPrefix("geoip:") || $0.lowercased().hasPrefix("geosite:") }
    }

    var geoKey: String { "\(geoipURL)|\(geositeURL)" }

    enum CodingKeys: String, CodingKey {
        case name, globalProxy, remoteDNSType, remoteDNSDomain, remoteDNSIP
        case domesticDNSType, domesticDNSDomain, domesticDNSIP, geoipURL, geositeURL
        case dnsHosts, directSites, directIP, proxySites, proxyIP, blockSites, blockIP
        case domainStrategy, isBuiltIn, subscriptionID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = RoutingProfile(name: "")
        name = try c.decode(String.self, forKey: .name)
        globalProxy = c.value(.globalProxy, d.globalProxy)
        remoteDNSType = c.value(.remoteDNSType, d.remoteDNSType)
        remoteDNSDomain = c.value(.remoteDNSDomain, d.remoteDNSDomain)
        remoteDNSIP = c.value(.remoteDNSIP, d.remoteDNSIP)
        domesticDNSType = c.value(.domesticDNSType, d.domesticDNSType)
        domesticDNSDomain = c.value(.domesticDNSDomain, d.domesticDNSDomain)
        domesticDNSIP = c.value(.domesticDNSIP, d.domesticDNSIP)
        geoipURL = c.value(.geoipURL, d.geoipURL)
        geositeURL = c.value(.geositeURL, d.geositeURL)
        dnsHosts = c.value(.dnsHosts, d.dnsHosts)
        directSites = c.value(.directSites, d.directSites)
        directIP = c.value(.directIP, d.directIP)
        proxySites = c.value(.proxySites, d.proxySites)
        proxyIP = c.value(.proxyIP, d.proxyIP)
        blockSites = c.value(.blockSites, d.blockSites)
        blockIP = c.value(.blockIP, d.blockIP)
        domainStrategy = c.value(.domainStrategy, d.domainStrategy)
        isBuiltIn = c.value(.isBuiltIn, d.isBuiltIn)
        subscriptionID = c.value(.subscriptionID, d.subscriptionID)
    }
}

// MARK: - Settings

struct AppSettings: Codable, Hashable {
    var pingType: PingType = .proxyGET
    var testURL = "https://www.gstatic.com/generate_204"
    var pingTimeout = 7
    var pingConcurrency = 8
    var pingOnOpen = true
    var autoTopK = 5
    var autoProbeMinutes = 3
    var autoConnectOnLaunch = false
    var updateSubscriptionsOnOpen = true
    var userAgent = "Strela/1.0"
    var sendHWID = true
    var ageEncryption = true
    var onDemand = false
    var excludeLocalNetworks = true
    var includeAllNetworks = false
    var excludeAPNs = true
    var enableIPv6 = false
    var mtu = 1500
    var sniffing = true
    var mux = false
    var fragment = FragmentSettings()
    var logLevel = "warning"
    var sortOrder: ServerSortOrder = .none

    init() {}

    enum CodingKeys: String, CodingKey {
        case pingType, testURL, pingTimeout, pingConcurrency, pingOnOpen, autoTopK, autoProbeMinutes
        case autoConnectOnLaunch, updateSubscriptionsOnOpen, userAgent, sendHWID, ageEncryption
        case onDemand, excludeLocalNetworks, includeAllNetworks, excludeAPNs, enableIPv6, mtu
        case sniffing, mux, fragment, logLevel, sortOrder
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        pingType = c.value(.pingType, d.pingType)
        testURL = c.value(.testURL, d.testURL)
        pingTimeout = c.value(.pingTimeout, d.pingTimeout)
        pingConcurrency = c.value(.pingConcurrency, d.pingConcurrency)
        pingOnOpen = c.value(.pingOnOpen, d.pingOnOpen)
        autoTopK = c.value(.autoTopK, d.autoTopK)
        autoProbeMinutes = c.value(.autoProbeMinutes, d.autoProbeMinutes)
        autoConnectOnLaunch = c.value(.autoConnectOnLaunch, d.autoConnectOnLaunch)
        updateSubscriptionsOnOpen = c.value(.updateSubscriptionsOnOpen, d.updateSubscriptionsOnOpen)
        userAgent = c.value(.userAgent, d.userAgent)
        sendHWID = c.value(.sendHWID, d.sendHWID)
        ageEncryption = c.value(.ageEncryption, d.ageEncryption)
        onDemand = c.value(.onDemand, d.onDemand)
        excludeLocalNetworks = c.value(.excludeLocalNetworks, d.excludeLocalNetworks)
        includeAllNetworks = c.value(.includeAllNetworks, d.includeAllNetworks)
        excludeAPNs = c.value(.excludeAPNs, d.excludeAPNs)
        enableIPv6 = c.value(.enableIPv6, d.enableIPv6)
        mtu = c.value(.mtu, d.mtu)
        sniffing = c.value(.sniffing, d.sniffing)
        mux = c.value(.mux, d.mux)
        fragment = c.value(.fragment, d.fragment)
        logLevel = c.value(.logLevel, d.logLevel)
        sortOrder = c.value(.sortOrder, d.sortOrder)
    }
}

/// Global settings merged with the active subscription's provider options.
struct EffectiveSettings {
    var pingType: PingType
    var testURL: String
    var pingTimeout: Int
    var pingConcurrency: Int
    var autoTopK: Int
    var autoProbeMinutes: Int
    var sniffing: Bool
    var mux: Bool
    var fragment: FragmentSettings
    var enableIPv6: Bool
    var mtu: Int
    var excludeLocalNetworks: Bool
    var includeAllNetworks: Bool
    var excludeAPNs: Bool
    var logLevel: String
    var routingEnabled: Bool
    var sortOrder: ServerSortOrder
}

struct GeoState: Codable, Hashable {
    var sourceKey: String?
    var updatedAt: Date?
}

// MARK: - App state

struct AppState: Codable {
    var subscriptions: [ProxySubscription] = []
    var servers: [ServerNode] = []
    var selection: ServerSelection = .none
    var settings = AppSettings()
    var routingProfiles: [RoutingProfile] = []
    var activeRoutingName: String?
    var routingEnabled = true
    var userPickedRouting = false
    var geo = GeoState()
    var ageSecretKey: String?
    var agePublicKey: String?
    var lastUsedServer: UUID?

    init() {}

    enum CodingKeys: String, CodingKey {
        case subscriptions, servers, selection, settings, routingProfiles, activeRoutingName
        case routingEnabled, userPickedRouting, geo, ageSecretKey, agePublicKey, lastUsedServer
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppState()
        subscriptions = c.value(.subscriptions, d.subscriptions)
        servers = c.value(.servers, d.servers)
        selection = c.value(.selection, d.selection)
        settings = c.value(.settings, d.settings)
        routingProfiles = c.value(.routingProfiles, d.routingProfiles)
        activeRoutingName = c.value(.activeRoutingName, d.activeRoutingName)
        routingEnabled = c.value(.routingEnabled, d.routingEnabled)
        userPickedRouting = c.value(.userPickedRouting, d.userPickedRouting)
        geo = c.value(.geo, d.geo)
        ageSecretKey = c.value(.ageSecretKey, d.ageSecretKey)
        agePublicKey = c.value(.agePublicKey, d.agePublicKey)
        lastUsedServer = c.value(.lastUsedServer, d.lastUsedServer)
    }
}

// MARK: - Tunnel plan (written by the app, read by the extension)

struct TunnelNetwork: Codable, Equatable {
    var mtu: Int
    var excludeLAN: Bool
}

struct TunnelPlan: Codable {
    /// Xray config; test inbound ports and metrics port are 0 and assigned by the extension.
    var configJSON: String
    var network: TunnelNetwork
    var title: String
    var isAuto: Bool
    /// Test inbound tag → server id (for latency tests while connected).
    var testInbounds: [String: UUID]
    /// Server id (uuidString) → endpoint (for TCP tests).
    var endpoints: [String: ServerEndpoint]
    /// Outbound tag → display name.
    var tagNames: [String: String]
    /// Candidate tags of the leastPing balancer in auto mode.
    var autoTags: [String]
    /// Proxy hostnames to pre-resolve before the tunnel comes up.
    var serverDomains: [String]
    var createdAt: Date
    /// Same config without geoip/geosite rules: used by the extension if it cannot load geo files.
    var fallbackConfigJSON: String? = nil
}

enum TunnelConstants {
    static let ipv4Address = "198.18.0.1"
    static let ipv4Mask = "255.255.255.252"
    static let dnsServer = "198.18.0.2"
    static let ipv6Address = "fd00:7f:5:1::1"
    static let ipv6Prefix = 126
    static let lanIPv4: [(String, String)] = [
        ("10.0.0.0", "255.0.0.0"),
        ("172.16.0.0", "255.240.0.0"),
        ("192.168.0.0", "255.255.0.0"),
        ("169.254.0.0", "255.255.0.0"),
        ("224.0.0.0", "240.0.0.0"),
    ]
    /// Always routed directly (LAN, link-local, multicast).
    static let privateCIDRs = [
        "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16",
        "224.0.0.0/4", "255.255.255.255/32", "fc00::/7", "fe80::/10", "ff00::/8",
    ]
}
