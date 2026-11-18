import Foundation
import Network

/// Metadata a provider can send in HTTP headers or as `#key: value` lines in the body (Happ-compatible).
struct SubscriptionMeta {
    var title: String?
    var userInfo: SubscriptionUserInfo?
    var updateInterval: Int?
    var supportURL: String?
    var webPageURL: String?
    var announce: String?
    var routingLinks: [String] = []
    var routingEnabled: Bool?
    var newURL: String?
    var fallbackURL: String?
    var options = ProviderOptions()

    mutating func applyHeaders(_ response: HTTPURLResponse) {
        var dispositionTitle: String?
        for (rawKey, rawValue) in response.allHeaderFields {
            guard let key = (rawKey as? String)?.lowercased(), let raw = rawValue as? String else { continue }
            let value = Self.fixEncoding(raw)
            if key == "content-disposition" { dispositionTitle = Self.filename(fromContentDisposition: value) }
            apply(key: key, value: value)
        }
        if title == nil, let dispositionTitle, !dispositionTitle.isEmpty { title = dispositionTitle }
    }

    mutating func apply(key rawKey: String, value rawValue: String) {
        let key = rawKey.lowercased().trimmed
        let value = rawValue.trimmed
        guard !value.isEmpty else { return }
        switch key {
        case "profile-title": title = Self.decodeText(value)
        case "subscription-userinfo": userInfo = Self.parseUserInfo(value)
        case "profile-update-interval": updateInterval = Int(value)
        case "support-url": supportURL = value
        case "profile-web-page-url": webPageURL = value
        case "announce": announce = Self.decodeText(value)
        case "routing":
            let normalized = value.replacingOccurrences(of: "\\n", with: "\n")
            routingLinks += normalized.components(separatedBy: .newlines).map(\.trimmed).filter { $0.contains("://") }
        case "routing-enable": routingEnabled = Self.bool(value)
        case "new-url": newURL = value
        case "fallback-url": fallbackURL = value
        case "ping-type": options.pingType = PingType(happValue: value)
        case "check-url-via-proxy": options.checkURL = value
        case "proxy-ping-timeout": options.pingTimeout = Int(value).map { min(max($0, 2), 30) }
        case "subscription-autoconnect": options.autoConnect = Self.bool(value)
        case "subscription-autoconnect-type": options.autoConnectType = value.lowercased()
        case "subscription-ping-onopen-enabled": options.pingOnOpen = Self.bool(value)
        case "subscription-auto-update-enable": options.autoUpdate = Self.bool(value)
        case "subscription-auto-update-open-enable": options.autoUpdateOnOpen = Self.bool(value)
        case "fragmentation-enable": options.fragmentation = Self.bool(value)
        case "fragmentation-packets": options.fragmentPackets = value
        case "fragmentation-length": options.fragmentLength = value
        case "fragmentation-interval": options.fragmentInterval = value
        case "fragmentation-maxsplit": options.fragmentMaxSplit = value
        case "sniffing-enable": options.sniffing = Self.bool(value)
        case "mux-enable": options.mux = Self.bool(value)
        case "hide-settings": options.hideSettings = Self.bool(value)
        case "subscriptions-sort-type": options.sortOrder = ServerSortOrder(rawValue: value.lowercased())
        case "change-user-agent": options.userAgent = value
        case "xray-tun-mtu": options.mtu = Int(value).map { min(max($0, 1280), 9000) }
        case "include-all-networks-enable": options.includeAllNetworks = Self.bool(value)
        case "exclude-local-networks-enable": options.excludeLocalNetworks = Self.bool(value)
        case "exclude-apns-enable": options.excludeAPNs = Self.bool(value)
        default: break
        }
    }

    /// Happ semantics: `true`/`1` enable, any other non-empty value disables.
    static func bool(_ value: String) -> Bool {
        let v = value.lowercased()
        return v == "true" || v == "1"
    }

    static func decodeText(_ value: String) -> String {
        if value.lowercased().hasPrefix("base64:") {
            let encoded = String(value.dropFirst("base64:".count))
            return Base64.decodeString(encoded) ?? encoded
        }
        return value
    }

    static func parseUserInfo(_ value: String) -> SubscriptionUserInfo {
        var info = SubscriptionUserInfo()
        for part in value.split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1).map { String($0).trimmed }
            guard pair.count == 2 else { continue }
            let number = Int64(pair[1]) ?? Int64(Double(pair[1]) ?? 0)
            switch pair[0].lowercased() {
            case "upload": info.upload = number
            case "download": info.download = number
            case "total": info.total = number
            case "expire": info.expire = number > 0 ? Date(timeIntervalSince1970: TimeInterval(number)) : nil
            default: break
            }
        }
        return info
    }

    /// Header values with raw UTF-8 bytes arrive as Latin-1; re-decode them.
    static func fixEncoding(_ value: String) -> String {
        guard value.unicodeScalars.contains(where: { $0.value >= 0x80 && $0.value <= 0xFF }),
              let data = value.data(using: .isoLatin1),
              let fixed = String(data: data, encoding: .utf8) else { return value }
        return fixed
    }

    static func filename(fromContentDisposition value: String) -> String? {
        if let range = value.range(of: "filename*=UTF-8''", options: .caseInsensitive) {
            let raw = value[range.upperBound...].components(separatedBy: ";").first ?? ""
            return raw.removingPercentEncoding?.trimmed
        }
        if let range = value.range(of: "filename=", options: .caseInsensitive) {
            let raw = value[range.upperBound...].components(separatedBy: ";").first ?? ""
            return raw.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")).nonEmpty
        }
        return nil
    }
}

struct ParsedNodes {
    var nodes: [ServerNode] = []
    var failed = 0
    var isJSON = false
    var meta = SubscriptionMeta()
}

enum ShareLinks {
    static let schemes = ["vless://", "vmess://", "trojan://", "ss://", "socks://", "socks5://", "hysteria2://", "hy2://"]

    static func isProxyLink(_ text: String) -> Bool {
        let lower = text.lowercased()
        return schemes.contains { lower.hasPrefix($0) }
    }

    /// Parses a subscription body or pasted text: share links, Base64 lists, Xray JSON configs,
    /// `#key: value` metadata lines and happ://routing links.
    static func parse(text rawText: String, groupID: UUID, meta: SubscriptionMeta = SubscriptionMeta()) -> ParsedNodes {
        var result = ParsedNodes(meta: meta)
        var text = rawText.trimmed
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }

        if text.hasPrefix("{") || text.hasPrefix("[") {
            if let parsed = parseJSON(text, groupID: groupID), !parsed.isEmpty {
                result.nodes = parsed
                result.isJSON = true
                return result
            }
        }

        if !text.contains("://"), let decoded = Base64.decodeString(text), decoded.contains("://") || decoded.contains("#") {
            text = decoded
        }

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmed
            guard !line.isEmpty else { continue }
            let lower = line.lowercased()
            if line.hasPrefix("#") {
                let body = line.dropFirst().trimmingCharacters(in: .whitespaces)
                if let colon = body.firstIndex(of: ":") {
                    let key = String(body[..<colon])
                    let value = String(body[body.index(after: colon)...])
                    if !key.contains(" ") { result.meta.apply(key: key, value: value) }
                }
                continue
            }
            if lower.contains("://routing/") || lower.contains("://autorouting/") {
                result.meta.routingLinks.append(line)
                continue
            }
            guard isProxyLink(line) else { continue }
            if let outbound = outbound(fromLink: line),
               let node = node(outbound: outbound, link: line, groupID: groupID) {
                result.nodes.append(node)
            } else {
                result.failed += 1
            }
        }
        return result
    }

    /// One share link → one Xray outbound (parsed and validated by libXray).
    static func outbound(fromLink raw: String) -> JSONObject? {
        var link = raw.trimmed
        if let converted = legacyVMessToAEAD(link) { link = converted }
        guard let outbounds = try? XrayCore.convertLinks(link), let first = outbounds.first else { return nil }
        return first
    }

    static func node(outbound source: JSONObject, link: String?, groupID: UUID,
                     dependencies: [JSONObject] = [], fullConfig: String? = nil,
                     name nameOverride: String? = nil, detail detailOverride: String? = nil) -> ServerNode? {
        var outbound = source
        let (tagName, tagDetail) = splitDescription((outbound["tag"] as? String) ?? "")
        let proto = ((outbound["protocol"] as? String) ?? "unknown").lowercased()
        let endpoint = Self.endpoint(of: outbound)
        var name = nameOverride?.nonEmpty ?? tagName.trimmed
        if name.isEmpty { name = "\(ServerNode.protocolTitle(proto)) \(endpoint?.host ?? "")".trimmed }
        outbound["tag"] = "proxy"
        guard let json = try? JSONUtil.string(outbound) else { return nil }
        let stream = outbound["streamSettings"] as? JSONObject ?? [:]
        let network = ((stream["network"] as? String) ?? (proto == "hysteria" ? "quic" : "raw")).lowercased()
        let security = ((stream["security"] as? String) ?? "none").lowercased()
        let deps = dependencies.isEmpty ? nil : (try? JSONUtil.string(dependencies))
        return ServerNode(
            groupID: groupID, name: name, detail: detailOverride ?? tagDetail,
            outbound: json, dependencies: deps, fullConfig: fullConfig, link: link,
            proto: proto, address: endpoint?.host ?? "", port: endpoint?.port ?? 0,
            network: network, security: security)
    }

    /// Happ puts a provider description into the name: `Name?serverDescription=<base64>`.
    static func splitDescription(_ tag: String) -> (String, String?) {
        guard let range = tag.range(of: "?serverDescription=") else { return (tag, nil) }
        let name = String(tag[..<range.lowerBound])
        let encoded = String(tag[range.upperBound...])
        return (name, Base64.decodeString(encoded) ?? encoded)
    }

    static func endpoint(of outbound: JSONObject) -> ServerEndpoint? {
        guard let settings = outbound["settings"] as? JSONObject else { return nil }
        if let host = settings["address"] as? String {
            return ServerEndpoint(host: host, port: JSONUtil.int(settings["port"]) ?? 0)
        }
        for key in ["vnext", "servers"] {
            if let first = (settings[key] as? [JSONObject])?.first, let host = first["address"] as? String {
                return ServerEndpoint(host: host, port: JSONUtil.int(first["port"]) ?? 0)
            }
        }
        if let peer = (settings["peers"] as? [JSONObject])?.first,
           let endpoint = peer["endpoint"] as? String,
           let colon = endpoint.lastIndex(of: ":") {
            let host = String(endpoint[..<colon]).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            return ServerEndpoint(host: host, port: Int(endpoint[endpoint.index(after: colon)...]) ?? 0)
        }
        return nil
    }

    static func isIPAddress(_ text: String) -> Bool {
        IPv4Address(text) != nil || IPv6Address(text) != nil
    }

    // MARK: JSON subscriptions (full Xray configs, Happ / Remnawave style)

    static func parseJSON(_ text: String, groupID: UUID) -> [ServerNode]? {
        guard let any = JSONUtil.any(text) else { return nil }
        let items: [JSONObject]
        if let array = any as? [JSONObject] {
            items = array
        } else if let object = any as? JSONObject {
            items = [object]
        } else {
            return nil
        }
        var nodes: [ServerNode] = []
        for (index, item) in items.enumerated() {
            if item["outbounds"] != nil {
                guard let (main, deps) = mainOutbound(of: item),
                      let configText = try? JSONUtil.string(item) else { continue }
                let name = (item["remarks"] as? String)?.nonEmpty ?? "Сервер \(index + 1)"
                var detail: String?
                if let meta = item["meta"] as? JSONObject, let encoded = meta["serverDescription"] as? String {
                    detail = Base64.decodeString(encoded) ?? encoded
                }
                if let node = node(outbound: main, link: nil, groupID: groupID, dependencies: deps,
                                   fullConfig: configText, name: name, detail: detail) {
                    nodes.append(node)
                }
            } else if item["protocol"] != nil, item["settings"] != nil {
                if let node = node(outbound: item, link: nil, groupID: groupID) { nodes.append(node) }
            }
        }
        return nodes
    }

    /// Picks the proxy outbound of a full config plus outbounds it dials through.
    static func mainOutbound(of config: JSONObject) -> (JSONObject, [JSONObject])? {
        guard let outbounds = config["outbounds"] as? [JSONObject], !outbounds.isEmpty else { return nil }
        let service: Set<String> = ["freedom", "blackhole", "dns", "loopback"]
        let main = outbounds.first { ($0["tag"] as? String) == "proxy" }
            ?? outbounds.first { !service.contains((($0["protocol"] as? String) ?? "").lowercased()) }
        guard let main else { return nil }
        var deps: [JSONObject] = []
        var seen: Set<String> = [(main["tag"] as? String) ?? ""]
        var queue = [main]
        while let current = queue.popLast() {
            guard let dialer = dialerProxy(of: current), !seen.contains(dialer),
                  let dep = outbounds.first(where: { ($0["tag"] as? String) == dialer }) else { continue }
            seen.insert(dialer)
            deps.append(dep)
            queue.append(dep)
        }
        return (main, deps)
    }

    static func dialerProxy(of outbound: JSONObject) -> String? {
        ((outbound["streamSettings"] as? JSONObject)?["sockopt"] as? JSONObject)?["dialerProxy"] as? String
    }

    // MARK: Legacy VMess (vmess://base64(JSON), v2rayN format)

    /// libXray parses only VMess AEAD links, so the legacy QR format is converted first.
    static func legacyVMessToAEAD(_ link: String) -> String? {
        guard link.lowercased().hasPrefix("vmess://") else { return nil }
        let body = String(link.dropFirst("vmess://".count))
        guard !body.contains("@"),
              let data = Base64.decode(body.components(separatedBy: "#").first ?? body),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? JSONObject else { return nil }
        func value(_ key: String) -> String { JSONUtil.text(object[key])?.trimmed ?? "" }

        let host = value("add")
        let id = value("id")
        let port = JSONUtil.int(object["port"]) ?? 0
        guard !host.isEmpty, !id.isEmpty, port > 0 else { return nil }

        var items: [URLQueryItem] = []
        items.append(URLQueryItem(name: "encryption", value: value("scy").nonEmpty ?? "auto"))
        let network = value("net").lowercased().nonEmpty ?? "tcp"
        switch network {
        case "ws", "httpupgrade", "xhttp", "splithttp":
            items.append(URLQueryItem(name: "type", value: network == "splithttp" ? "xhttp" : network))
            if let path = value("path").nonEmpty { items.append(URLQueryItem(name: "path", value: path)) }
            if let hostHeader = value("host").nonEmpty { items.append(URLQueryItem(name: "host", value: hostHeader)) }
        case "grpc":
            items.append(URLQueryItem(name: "type", value: "grpc"))
            if let service = value("path").nonEmpty { items.append(URLQueryItem(name: "serviceName", value: service)) }
            if value("type") == "multi" { items.append(URLQueryItem(name: "mode", value: "multi")) }
        case "kcp", "mkcp":
            items.append(URLQueryItem(name: "type", value: "kcp"))
        default:
            items.append(URLQueryItem(name: "type", value: "tcp"))
            if value("type") == "http" {
                items.append(URLQueryItem(name: "headerType", value: "http"))
                if let hostHeader = value("host").nonEmpty { items.append(URLQueryItem(name: "host", value: hostHeader)) }
                if let path = value("path").nonEmpty { items.append(URLQueryItem(name: "path", value: path)) }
            }
        }
        let tls = value("tls").lowercased()
        if tls == "tls" || tls == "reality" {
            items.append(URLQueryItem(name: "security", value: tls))
            if let sni = value("sni").nonEmpty ?? value("host").nonEmpty {
                items.append(URLQueryItem(name: "sni", value: sni))
            }
            if let alpn = value("alpn").nonEmpty { items.append(URLQueryItem(name: "alpn", value: alpn)) }
            if let fp = value("fp").nonEmpty { items.append(URLQueryItem(name: "fp", value: fp)) }
            if tls == "reality" {
                if let pbk = value("pbk").nonEmpty { items.append(URLQueryItem(name: "pbk", value: pbk)) }
                if let sid = value("sid").nonEmpty { items.append(URLQueryItem(name: "sid", value: sid)) }
            }
        } else {
            items.append(URLQueryItem(name: "security", value: "none"))
        }

        var components = URLComponents()
        components.scheme = "vmess"
        components.user = id
        if host.contains(":") {
            components.percentEncodedHost = "[\(host)]"
        } else {
            components.host = host
        }
        components.port = port
        components.queryItems = items
        if let name = value("ps").nonEmpty { components.fragment = name }
        return components.string
    }
}
