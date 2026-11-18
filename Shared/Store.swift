import Foundation

/// Resolves the App Group shared by the app and the tunnel extension.
/// The group is detected at runtime, so builds re-signed by GBox / ESign / Sideloadly keep working.
enum AppGroup {
    static let identifier: String = resolve()

    static var containerURL: URL {
        if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) {
            return url
        }
        let fallback = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
        return fallback
    }

    static var isAvailable: Bool {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) != nil
    }

    private static func resolve() -> String {
        var candidates: [String] = []
        if let fromPlist = Bundle.main.object(forInfoDictionaryKey: "AppGroupID") as? String,
           !fromPlist.isEmpty, !fromPlist.contains("$(") {
            candidates.append(fromPlist)
        }
        candidates.append(contentsOf: ProvisioningProfile.embedded?.appGroups ?? [])
        for id in candidates where !id.contains("*") {
            if FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id) != nil {
                return id
            }
        }
        return candidates.first ?? "group.com.example.strela"
    }

    /// Bundle id of the packet tunnel extension, taken from the embedded .appex.
    static var tunnelBundleIdentifier: String {
        if let pluginsURL = Bundle.main.builtInPlugInsURL,
           let items = try? FileManager.default.contentsOfDirectory(at: pluginsURL, includingPropertiesForKeys: nil) {
            for url in items where url.pathExtension == "appex" {
                guard let bundle = Bundle(url: url),
                      let ext = bundle.object(forInfoDictionaryKey: "NSExtension") as? [String: Any],
                      ext["NSExtensionPointIdentifier"] as? String == "com.apple.networkextension.packet-tunnel",
                      let id = bundle.bundleIdentifier else { continue }
                return id
            }
        }
        return (Bundle.main.bundleIdentifier ?? "com.example.strela") + ".tunnel"
    }
}

struct ProvisioningProfile {
    let appGroups: [String]
    let networkExtension: [String]
    let teamID: String?
    let teamName: String?
    let name: String?
    let expiration: Date?

    /// false → the signature has no Network Extension entitlement and VPN cannot start.
    /// (`ProvisioningProfile.embedded` itself is nil without a profile: TrollStore, simulator.)
    var hasNetworkExtension: Bool {
        networkExtension.contains { $0 == "packet-tunnel-provider" || $0 == "*" }
    }

    static let embedded: ProvisioningProfile? = load()

    private static func load() -> ProvisioningProfile? {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex)
        else { return nil }
        let plistData = data.subdata(in: start.lowerBound..<end.upperBound)
        guard let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any]
        else { return nil }
        let entitlements = plist["Entitlements"] as? [String: Any] ?? [:]
        let networkExtension: [String]
        switch entitlements["com.apple.developer.networking.networkextension"] {
        case let list as [String]: networkExtension = list
        case let single as String: networkExtension = [single]
        default: networkExtension = []
        }
        return ProvisioningProfile(
            appGroups: entitlements["com.apple.security.application-groups"] as? [String] ?? [],
            networkExtension: networkExtension,
            teamID: (plist["TeamIdentifier"] as? [String])?.first,
            teamName: plist["TeamName"] as? String,
            name: plist["Name"] as? String,
            expiration: plist["ExpirationDate"] as? Date
        )
    }
}

enum Store {
    static var root: URL { AppGroup.containerURL }
    static var stateURL: URL { root.appendingPathComponent("state.json") }
    static var planURL: URL { root.appendingPathComponent("tunnel-plan.json") }
    static var tunnelErrorURL: URL { root.appendingPathComponent("tunnel-error.txt") }
    static var geoDir: URL { directory("Geo") }
    static var logsDir: URL { directory("Logs") }
    static var xrayLogURL: URL { logsDir.appendingPathComponent("xray.log") }
    static var appLogURL: URL { logsDir.appendingPathComponent("app.log") }

    private static func directory(_ name: String) -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }

    static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try makeDecoder().decode(type, from: data)
        } catch {
            AppLog.write("Не удалось прочитать \(url.lastPathComponent): \(error)")
            return nil
        }
    }

    static func save<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try makeEncoder().encode(value)
        try data.write(to: url, options: [.atomic])
    }

    static func loadState() -> AppState? { load(AppState.self, from: stateURL) }

    static func saveState(_ state: AppState) {
        do { try save(state, to: stateURL) } catch { AppLog.write("Ошибка сохранения состояния: \(error)") }
    }

    static func loadPlan() -> TunnelPlan? { load(TunnelPlan.self, from: planURL) }

    static func savePlan(_ plan: TunnelPlan) throws { try save(plan, to: planURL) }

    static func writeTunnelError(_ message: String?) {
        if let message {
            try? Data(message.utf8).write(to: tunnelErrorURL, options: [.atomic])
        } else {
            try? FileManager.default.removeItem(at: tunnelErrorURL)
        }
    }

    static func readTunnelError() -> String? {
        guard let data = try? Data(contentsOf: tunnelErrorURL) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Returns the last `maxBytes` of a text file.
    static func tail(of url: URL, maxBytes: Int = 96 * 1024) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let offset = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: offset)
        let data = (try? handle.readToEnd()) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    static func truncateIfNeeded(_ url: URL, limit: Int) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.intValue, size > limit,
              let data = try? Data(contentsOf: url) else { return }
        try? data.suffix(limit / 2).write(to: url, options: [.atomic])
    }
}

enum AppLog {
    private static let queue = DispatchQueue(label: "strela.log")
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss"
        return formatter
    }()

    static func write(_ message: String) {
        let process = Bundle.main.bundleURL.pathExtension == "appex" ? "tunnel" : "app"
        queue.async {
            let line = "\(formatter.string(from: Date())) [\(process)] \(message)\n"
            let url = Store.appLogURL
            if let handle = try? FileHandle(forWritingTo: url) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
            Store.truncateIfNeeded(url, limit: 512 * 1024)
        }
    }
}
