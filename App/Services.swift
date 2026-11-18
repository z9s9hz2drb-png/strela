import BackgroundTasks
import CryptoKit
import Foundation
import Security
import UIKit

// MARK: - Device identity (Happ / Remnawave HWID headers)

@MainActor
enum DeviceInfo {
    /// Stable per-device id for `x-hwid` (kept in the Keychain, survives reinstalls).
    static var hwid: String {
        if let stored = Keychain.get("hwid") { return stored }
        let seed = (UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString) + model
        let digest = SHA256.hash(data: Data(seed.utf8)).map { String(format: "%02x", $0) }.joined()
        let value = String(digest.prefix(16)).uppercased()
        Keychain.set("hwid", value)
        return value
    }

    static var osName: String { "iOS" }

    static var osVersion: String { UIDevice.current.systemVersion }

    /// Hardware identifier like "iPad13,4".
    static var model: String {
        var info = utsname()
        uname(&info)
        let machine = withUnsafeBytes(of: &info.machine) { buffer in
            String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        }
        return machine.isEmpty ? UIDevice.current.model : machine
    }

    static var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(version) (\(build))"
    }
}

enum Keychain {
    private static let service = "strela"

    static func get(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ key: String, _ value: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}

// MARK: - Subscriptions

enum SubscriptionError: LocalizedError {
    case badURL
    case http(Int, String?)
    case empty(String?)

    var errorDescription: String? {
        switch self {
        case .badURL: return "Некорректная ссылка подписки"
        case .http(let code, let announce):
            if let announce, !announce.isEmpty { return "Ошибка \(code): \(announce)" }
            return code == 404 ? "Подписка не найдена (404). Возможно, превышен лимит устройств." : "Сервер ответил кодом \(code)"
        case .empty(let announce):
            if let announce, !announce.isEmpty { return "Нет серверов: \(announce)" }
            return "В подписке нет поддерживаемых серверов"
        }
    }
}

struct SubscriptionFetchResult {
    var meta: SubscriptionMeta
    var nodes: [ServerNode]
    var isJSON: Bool
    var failed: Int
}

enum SubscriptionService {
    @MainActor
    static func fetch(_ subscription: ProxySubscription, settings: AppSettings,
                      agePublicKey: String?, ageSecretKey: String?) async throws -> SubscriptionFetchResult {
        var headers: [String: String] = [
            "User-Agent": subscription.options.userAgent ?? settings.userAgent,
            "Accept": "*/*",
        ]
        if settings.sendHWID {
            headers["x-hwid"] = DeviceInfo.hwid
            headers["x-device-os"] = DeviceInfo.osName
            headers["x-ver-os"] = DeviceInfo.osVersion
            headers["x-device-model"] = DeviceInfo.model
        }
        if settings.ageEncryption, let agePublicKey { headers["X-Age-Public-Key"] = agePublicKey }

        var candidates = [subscription.url]
        if let fallback = subscription.fallbackURL?.nonEmpty, fallback != subscription.url { candidates.append(fallback) }
        var lastError: Error = SubscriptionError.badURL
        for candidate in candidates {
            guard let url = URL(string: candidate.trimmed) else { continue }
            do {
                let (data, response) = try await download(url, headers: headers)
                return try await parse(data: data, response: response, groupID: subscription.id, ageSecretKey: ageSecretKey)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private static func download(_ url: URL, headers: [String: String]) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SubscriptionError.http(0, nil) }
        guard (200..<300).contains(http.statusCode) else {
            var meta = SubscriptionMeta()
            meta.applyHeaders(http)
            throw SubscriptionError.http(http.statusCode, meta.announce)
        }
        return (data, http)
    }

    static func parse(data: Data, response: HTTPURLResponse?, groupID: UUID, ageSecretKey: String?) async throws -> SubscriptionFetchResult {
        var meta = SubscriptionMeta()
        if let response { meta.applyHeaders(response) }
        let headerMeta = meta
        let raw = String(decoding: data, as: UTF8.self)
        let parsed = await Task.detached(priority: .userInitiated) { () -> ParsedNodes in
            var text = raw
            if text.contains("-----BEGIN AGE ENCRYPTED FILE-----") {
                text = (try? XrayCore.decodeSubscription(text, ageSecretKey: ageSecretKey)) ?? text
            }
            return ShareLinks.parse(text: text, groupID: groupID, meta: headerMeta)
        }.value
        guard !parsed.nodes.isEmpty else { throw SubscriptionError.empty(parsed.meta.announce) }
        return SubscriptionFetchResult(meta: parsed.meta, nodes: parsed.nodes, isJSON: parsed.isJSON, failed: parsed.failed)
    }
}

// MARK: - Geo files

enum GeoFiles {
    static var geoipURL: URL { Store.geoDir.appendingPathComponent("geoip.dat") }
    static var geositeURL: URL { Store.geoDir.appendingPathComponent("geosite.dat") }

    static var hasGeoIP: Bool { FileManager.default.fileExists(atPath: geoipURL.path) }
    static var hasGeoSite: Bool { FileManager.default.fileExists(atPath: geositeURL.path) }

    static func describe(_ url: URL) -> String {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return "нет" }
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let date = (attributes[.modificationDate] as? Date).map {
            $0.formatted(date: .abbreviated, time: .shortened)
        } ?? ""
        return "\(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) · \(date)"
    }

    static func download(geoip: String, geosite: String) async throws {
        try await fetch(geoip, to: geoipURL)
        try await fetch(geosite, to: geositeURL)
    }

    private static func fetch(_ source: String, to destination: URL) async throws {
        var lastError: Error = URLError(.badURL)
        for candidate in mirrors(for: source) {
            guard let url = URL(string: candidate) else { continue }
            do {
                var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
                request.setValue("Mozilla/5.0 (iPad; CPU OS 17_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
                let (temporary, response) = try await URLSession.shared.download(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    throw URLError(.badServerResponse)
                }
                let attributes = try? FileManager.default.attributesOfItem(atPath: temporary.path)
                let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
                guard size > 1024 else { throw URLError(.zeroByteResource) }
                if FileManager.default.fileExists(atPath: destination.path) {
                    _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
                } else {
                    try FileManager.default.moveItem(at: temporary, to: destination)
                }
                return
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    /// raw.githubusercontent.com is sometimes slow in Russia; jsDelivr mirrors the same file.
    static func mirrors(for source: String) -> [String] {
        var list = [source]
        let prefix = "https://raw.githubusercontent.com/"
        if source.hasPrefix(prefix) {
            let parts = source.dropFirst(prefix.count).split(separator: "/", maxSplits: 3).map(String.init)
            if parts.count == 4 {
                list.append("https://cdn.jsdelivr.net/gh/\(parts[0])/\(parts[1])@\(parts[2])/\(parts[3])")
            }
        }
        return list
    }
}

// MARK: - In-app Xray sandbox (latency tests and config validation while the VPN is off)

/// libXray allows one managed core per process, so every call is serialized here.
actor CoreSandbox {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }

    func version() -> String {
        XrayCore.version()
    }

    func validate(_ plan: TunnelPlan) async throws {
        await acquire()
        defer { release() }
        let copy = try ConfigFinalizer.validationCopy(plan.configJSON, assetDir: Store.geoDir.path)
        try XrayCore.test(configJSON: copy)
    }

    func latency(servers: [ServerNode], settings: EffectiveSettings) async -> [UUID: Int] {
        guard !servers.isEmpty else { return [:] }
        await acquire()
        defer { release() }
        let timeout = TimeInterval(max(2, settings.pingTimeout))
        var failed: [UUID: Int] = [:]
        for server in servers { failed[server.id] = -1 }

        if settings.pingType == .tcp {
            let jobs = servers.map { LatencyTester.TCPJob(id: $0.id, host: $0.address, port: $0.port) }
            let results = await LatencyTester.tcpBatch(jobs, timeout: timeout, concurrency: settings.pingConcurrency)
            return failed.merging(results) { _, new in new }
        }

        guard let url = URL(string: settings.testURL),
              let built = ConfigBuilder.testConfig(servers: servers, settings: settings) else { return failed }
        do {
            let config = try ConfigFinalizer.finalize(configJSON: built.json, tunFD: nil,
                                                      assetDir: Store.geoDir.path, hosts: [:])
            XrayCore.stop()
            try XrayCore.run(configJSON: config.json)
            var jobs: [LatencyTester.HTTPJob] = []
            for (tag, id) in built.inbounds {
                if let port = config.testPorts[tag] { jobs.append(LatencyTester.HTTPJob(id: id, port: port)) }
            }
            let results = await LatencyTester.httpBatch(jobs, url: url, method: settings.pingType.httpMethod,
                                                        timeout: timeout, concurrency: settings.pingConcurrency)
            XrayCore.stop()
            return failed.merging(results) { _, new in new }
        } catch {
            XrayCore.stop()
            AppLog.write("Тест задержки: \(error.localizedDescription)")
            return failed
        }
    }
}

// MARK: - Background App Refresh

enum BackgroundRefresh {
    /// Listed in Info.plist → BGTaskSchedulerPermittedIdentifiers.
    static let identifier = "strela.subscriptions.refresh"

    static func schedule(afterHours hours: Double) {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: max(1, hours) * 3600)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            AppLog.write("Фоновое обновление не запланировано: \(error.localizedDescription)")
        }
    }
}
