import Foundation
import NetworkExtension
import Observation

struct IPCError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor
@Observable
final class VPNController {
    private(set) var status: NEVPNStatus = .invalid
    private(set) var connectedDate: Date?
    /// Plan the running tunnel was started with (needed for in-tunnel latency tests).
    private(set) var activePlan: TunnelPlan?
    @ObservationIgnored var onUnexpectedDisconnect: (@MainActor (String) -> Void)?

    @ObservationIgnored private var manager: NETunnelProviderManager?
    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private var previousStatus: NEVPNStatus = .invalid

    var isConnected: Bool { status == .connected }
    var isActive: Bool { status == .connected || status == .connecting || status == .reasserting }
    var isBusy: Bool { status == .connecting || status == .disconnecting || status == .reasserting }

    func load() async {
        do {
            let managers = try await Self.loadAll()
            let bundleID = AppGroup.tunnelBundleIdentifier
            let ours = managers.first {
                ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == bundleID
            } ?? managers.first
            if let ours { attach(ours) }
        } catch {
            AppLog.write("Не удалось загрузить настройки VPN: \(error.localizedDescription)")
        }
    }

    func start(plan: TunnelPlan, settings: EffectiveSettings, onDemand: Bool) async throws {
        try? Store.savePlan(plan)
        Store.writeTunnelError(nil)
        let planData = try Store.makeEncoder().encode(plan)
        let manager = try await preparedManager(settings: settings, onDemand: onDemand, planData: planData)
        do {
            // The plan travels with the start request, so the tunnel does not depend on the App Group.
            try manager.connection.startVPNTunnel(options: ["plan": planData as NSData])
        } catch {
            throw IPCError(message: "Не удалось запустить VPN: \(error.localizedDescription)")
        }
        activePlan = plan
    }

    func stop() async {
        guard let manager else { return }
        if manager.isOnDemandEnabled {
            manager.isOnDemandEnabled = false
            try? await Self.save(manager)
        }
        manager.connection.stopVPNTunnel()
    }

    /// Applies a new plan: hot reload inside the running tunnel when possible, otherwise reconnect.
    func apply(plan: TunnelPlan, settings: EffectiveSettings, onDemand: Bool) async throws {
        let previous = activePlan
        try? Store.savePlan(plan)
        if isConnected, let previous, previous.network == plan.network {
            do {
                let reply = try await send(IPCRequest(command: .reload, plan: plan))
                let text = String(decoding: reply, as: UTF8.self)
                if text == "ok" {
                    activePlan = plan
                    return
                }
                AppLog.write("Горячая перезагрузка не удалась: \(text)")
            } catch {
                AppLog.write("Горячая перезагрузка не удалась: \(error.localizedDescription)")
            }
        }
        await stop()
        await waitUntilDisconnected(timeout: 8)
        try await start(plan: plan, settings: settings, onDemand: onDemand)
    }

    func send(_ request: IPCRequest) async throws -> Data {
        guard let session = manager?.connection as? NETunnelProviderSession, status == .connected else {
            throw IPCError(message: "VPN не подключён")
        }
        let data = try JSONEncoder().encode(request)
        return try await withCheckedThrowingContinuation { continuation in
            do {
                try session.sendProviderMessage(data) { response in
                    if let response {
                        continuation.resume(returning: response)
                    } else {
                        continuation.resume(throwing: IPCError(message: "Туннель не ответил"))
                    }
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    func tunnelLogs() async throws -> (xray: String, app: String) {
        let data = try await send(IPCRequest(command: .logs))
        let logs = try JSONDecoder().decode([String: String].self, from: data)
        return (logs["xray"] ?? "", logs["app"] ?? "")
    }

    func tunnelStatus() async throws -> TunnelStatus {
        let data = try await send(IPCRequest(command: .status))
        return try Store.makeDecoder().decode(TunnelStatus.self, from: data)
    }

    func ping(ids: [UUID], settings: EffectiveSettings) async throws -> [UUID: Int] {
        let request = PingRequest(serverIDs: ids, type: settings.pingType, url: settings.testURL,
                                  timeout: settings.pingTimeout, concurrency: settings.pingConcurrency)
        let data = try await send(IPCRequest(command: .ping, ping: request))
        let response = try JSONDecoder().decode(PingResponse.self, from: data)
        var results: [UUID: Int] = [:]
        for (key, value) in response.results {
            if let id = UUID(uuidString: key) { results[id] = value }
        }
        return results
    }

    func removeConfiguration() async {
        guard let manager else { return }
        manager.connection.stopVPNTunnel()
        try? await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.removeFromPreferences { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
        self.manager = nil
        status = .invalid
    }

    // MARK: Private

    private func preparedManager(settings: EffectiveSettings, onDemand: Bool, planData: Data) async throws -> NETunnelProviderManager {
        let manager = self.manager ?? NETunnelProviderManager()
        let proto = (manager.protocolConfiguration as? NETunnelProviderProtocol) ?? NETunnelProviderProtocol()
        proto.providerBundleIdentifier = AppGroup.tunnelBundleIdentifier
        // Copy for system-initiated starts (VPN on demand) when the App Group is unavailable.
        proto.providerConfiguration = planData.count <= 256 * 1024 ? ["plan": planData] : nil
        proto.serverAddress = "Xray"
        proto.disconnectOnSleep = false
        proto.includeAllNetworks = settings.includeAllNetworks
        proto.excludeLocalNetworks = settings.excludeLocalNetworks
        proto.excludeAPNs = settings.excludeAPNs
        manager.protocolConfiguration = proto
        manager.localizedDescription = "Strela"
        manager.isEnabled = true
        let rule = NEOnDemandRuleConnect()
        rule.interfaceTypeMatch = .any
        manager.onDemandRules = [rule]
        manager.isOnDemandEnabled = onDemand
        do {
            try await Self.save(manager)
            try await Self.reload(manager)
        } catch {
            throw IPCError(message: Self.describeConfigurationError(error))
        }
        if self.manager !== manager { attach(manager) }
        return manager
    }

    private func attach(_ manager: NETunnelProviderManager) {
        self.manager = manager
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange, object: manager.connection, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    private func refresh() {
        guard let manager else {
            status = .invalid
            return
        }
        let newStatus = manager.connection.status
        status = newStatus
        connectedDate = manager.connection.connectedDate
        if newStatus == .connected, activePlan == nil { activePlan = Store.loadPlan() }
        if newStatus == .disconnected || newStatus == .invalid {
            if previousStatus == .connecting || previousStatus == .connected || previousStatus == .reasserting {
                if let message = Store.readTunnelError() {
                    onUnexpectedDisconnect?(message)
                    Store.writeTunnelError(nil)
                } else if newStatus == .disconnected {
                    // Without a shared App Group the error file is invisible: ask the system instead.
                    manager.connection.fetchLastDisconnectError { [weak self] error in
                        guard let error else { return }
                        let nsError = error as NSError
                        let underlying = (nsError.userInfo[NSUnderlyingErrorKey] as? NSError)?.localizedDescription
                        let message = underlying ?? nsError.localizedDescription
                        Task { @MainActor in self?.onUnexpectedDisconnect?(message) }
                    }
                }
            }
            activePlan = nil
        }
        previousStatus = newStatus
    }

    /// Most common failure after third-party signing: the profile has no Network Extension entitlement.
    private static func describeConfigurationError(_ error: Error) -> String {
        let nsError = error as NSError
        let text = nsError.localizedDescription
        if nsError.domain == NEVPNErrorDomain || text.lowercased().contains("permission") {
            if ProvisioningProfile.embedded?.hasNetworkExtension == false {
                return "Подпись без права VPN (Network Extension). Переподпишите IPA сертификатом с поддержкой VPN."
            }
            if nsError.code == NEVPNError.Code.configurationReadWriteFailed.rawValue || text.lowercased().contains("permission") {
                return "iOS не дала создать VPN-профиль (\(text)). Обычно это значит, что сертификат подписи не поддерживает VPN (Network Extension)."
            }
        }
        return "Не удалось сохранить конфигурацию VPN: \(text)"
    }

    private func waitUntilDisconnected(timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, status != .disconnected, status != .invalid {
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
    }

    private static func loadAll() async throws -> [NETunnelProviderManager] {
        try await withCheckedThrowingContinuation { continuation in
            NETunnelProviderManager.loadAllFromPreferences { managers, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: managers ?? [])
                }
            }
        }
    }

    private static func save(_ manager: NETunnelProviderManager) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.saveToPreferences { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    private static func reload(_ manager: NETunnelProviderManager) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.loadFromPreferences { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }
}
