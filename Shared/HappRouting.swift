import Foundation

enum RoutingLinkAction {
    case add(RoutingProfile, activate: Bool)
    case remote(url: String, activate: Bool)
    case off
}

/// Happ-compatible routing profiles: `happ://routing/add/{base64}`, `.../onadd/{base64}`, `.../off`.
/// Any scheme is accepted (happ://, incy://, strela://), as in the Happ docs.
enum HappRouting {
    static func parse(link raw: String) -> RoutingLinkAction? {
        let text = raw.trimmed
        guard let range = text.range(of: "://routing/") ?? text.range(of: "://autorouting/") else { return nil }
        let rest = String(text[range.upperBound...])
        if rest.lowercased().hasPrefix("off") { return .off }
        var activate = true
        var payload = rest
        if rest.lowercased().hasPrefix("onadd/") {
            payload = String(rest.dropFirst("onadd/".count))
        } else if rest.lowercased().hasPrefix("add/") {
            activate = false
            payload = String(rest.dropFirst("add/".count))
        }
        payload = payload.removingPercentEncoding ?? payload
        if payload.lowercased().hasPrefix("http://") || payload.lowercased().hasPrefix("https://") {
            return .remote(url: payload, activate: activate)
        }
        guard let profile = profile(fromPayload: payload) else { return nil }
        return .add(profile, activate: activate)
    }

    /// Payload may be JSON, Base64(JSON) or a nested routing link.
    static func profile(fromPayload payload: String) -> RoutingProfile? {
        let text = payload.trimmed
        if text.contains("://routing/"), case .add(let profile, _)? = parse(link: text) { return profile }
        if text.hasPrefix("{"), let object = JSONUtil.object(text) { return profile(fromHapp: object) }
        if let decoded = Base64.decodeString(text), let object = JSONUtil.object(decoded.trimmed) {
            return profile(fromHapp: object)
        }
        return nil
    }

    static func profile(fromHapp object: JSONObject) -> RoutingProfile {
        func string(_ key: String) -> String? { JSONUtil.text(object[key])?.trimmed.nonEmpty }
        func list(_ key: String) -> [String] {
            if let array = object[key] as? [Any] {
                return array.compactMap { JSONUtil.text($0)?.trimmed.nonEmpty }
            }
            if let text = object[key] as? String {
                return text.split(whereSeparator: { $0 == "," || $0 == "\n" }).compactMap { String($0).trimmed.nonEmpty }
            }
            return []
        }
        func bool(_ key: String) -> Bool? {
            if let value = object[key] as? Bool { return value }
            if let value = string(key)?.lowercased() { return value == "true" || value == "1" }
            return nil
        }

        var profile = RoutingProfile(name: string("Name") ?? "Профиль провайдера")
        if let value = bool("GlobalProxy") { profile.globalProxy = value }
        if let value = string("RemoteDNSType") { profile.remoteDNSType = value }
        if let value = string("RemoteDNSDomain") { profile.remoteDNSDomain = value }
        if let value = string("RemoteDNSIP") { profile.remoteDNSIP = value }
        if let value = string("DomesticDNSType") { profile.domesticDNSType = value }
        if let value = string("DomesticDNSDomain") { profile.domesticDNSDomain = value }
        if let value = string("DomesticDNSIP") { profile.domesticDNSIP = value }
        if let value = string("Geoipurl") { profile.geoipURL = value }
        if let value = string("Geositeurl") { profile.geositeURL = value }
        if let hosts = object["DnsHosts"] as? [String: Any] {
            profile.dnsHosts = hosts.compactMapValues { JSONUtil.text($0) }
        }
        profile.directSites = list("DirectSites")
        profile.directIP = list("DirectIp")
        profile.proxySites = list("ProxySites")
        profile.proxyIP = list("ProxyIp")
        profile.blockSites = list("BlockSites")
        profile.blockIP = list("BlockIp")
        if let value = string("DomainStrategy") { profile.domainStrategy = value }
        return profile
    }

    static func happJSON(_ profile: RoutingProfile) -> JSONObject {
        [
            "Name": profile.name,
            "GlobalProxy": profile.globalProxy ? "true" : "false",
            "RemoteDNSType": profile.remoteDNSType,
            "RemoteDNSDomain": profile.remoteDNSDomain,
            "RemoteDNSIP": profile.remoteDNSIP,
            "DomesticDNSType": profile.domesticDNSType,
            "DomesticDNSDomain": profile.domesticDNSDomain,
            "DomesticDNSIP": profile.domesticDNSIP,
            "Geoipurl": profile.geoipURL,
            "Geositeurl": profile.geositeURL,
            "LastUpdated": String(Int(Date().timeIntervalSince1970)),
            "DnsHosts": profile.dnsHosts,
            "DirectSites": profile.directSites,
            "DirectIp": profile.directIP,
            "ProxySites": profile.proxySites,
            "ProxyIp": profile.proxyIP,
            "BlockSites": profile.blockSites,
            "BlockIp": profile.blockIP,
            "DomainStrategy": profile.domainStrategy,
            "FakeDNS": "false",
        ]
    }

    /// Link understood by this app and by Happ.
    static func exportLink(_ profile: RoutingProfile) -> String {
        let json = (try? JSONUtil.string(happJSON(profile))) ?? "{}"
        return "happ://routing/add/" + Base64.encode(json)
    }
}

enum RoutingPresets {
    static let smartName = "🇷🇺 Умный: РФ напрямую"
    static let smartNoAdsName = "🛡 Умный + без рекламы"
    static let blockedName = "🚫 Только заблокированное"
    static let globalName = "🌍 Всё через VPN"

    static var builtInNames: Set<String> { [smartName, smartNoAdsName, blockedName, globalName] }

    static var all: [RoutingProfile] { [smart, smartNoAds, blockedOnly, global] }

    static let russianDomains = [
        "geosite:category-ru",
        "geosite:ru-available-only-inside",
        "domain:ru", "domain:su", "domain:xn--p1ai", "domain:xn--p1acf",
        "domain:xn--80adxhks", "domain:xn--d1acj3b", "domain:moscow", "domain:tatar",
    ]

    static var smart: RoutingProfile {
        var profile = RoutingProfile(name: smartName)
        profile.isBuiltIn = true
        profile.globalProxy = true
        profile.directSites = russianDomains
        profile.directIP = ["geoip:ru"]
        return profile
    }

    static var smartNoAds: RoutingProfile {
        var profile = smart
        profile.name = smartNoAdsName
        profile.blockSites = ["geosite:category-ads-all"]
        return profile
    }

    static var blockedOnly: RoutingProfile {
        var profile = RoutingProfile(name: blockedName)
        profile.isBuiltIn = true
        profile.globalProxy = false
        profile.proxySites = [
            "geosite:ru-blocked", "geosite:youtube", "geosite:discord", "geosite:meta",
            "geosite:twitter", "geosite:openai", "geosite:anthropic", "geosite:telegram",
        ]
        profile.proxyIP = ["geoip:ru-blocked", "geoip:telegram"]
        return profile
    }

    static var global: RoutingProfile {
        var profile = RoutingProfile(name: globalName)
        profile.isBuiltIn = true
        profile.globalProxy = true
        profile.domainStrategy = "AsIs"
        return profile
    }
}
