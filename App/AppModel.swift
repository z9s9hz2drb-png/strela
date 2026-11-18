import Foundation
import NetworkExtension
import Observation
import UIKit

struct Banner: Identifiable, Equatable {
    let id = UUID()
    var text: String
    var isError: Bool
}

@MainActor
@Observable
final class AppModel {
    var state: AppState
    let vpn = VPNController()
    var banner: Banner?
    var testingGroups: Set<UUID> = []
    var updatingSubscriptions: Set<UUID> = []
    var isConnecting = false
    var tunnelStatus: TunnelStatus?
    var speedUp: Double = 0
    var speedDown: Double = 0
    var geoBusy = false
    var coreVersion = "—"
    var isForeground = true

    @ObservationIgnored private let sandbox = CoreSandbox()
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var bannerTask: Task<Void, Never>?
    @ObservationIgnored private var lastSample: (date: Date, up: Int64, down: Int64)?
    @ObservationIgnored private var bootstrapped = false

    init() {
        var loaded = Store.loadState() ?? AppState()
        Self.ensureBuiltInProfiles(&loaded)
        state = loaded
        vpn.onUnexpectedDisconnect = { [weak self] message in
            self?.show(message, error: true)
        }
    }

    private static func ensureBuiltInProfiles(_ state: inout AppState) {
        for preset in RoutingPresets.all.reversed() {
            if let index = state.routingProfiles.firstIndex(where: { $0.name == preset.name }) {
                state.routingProfiles[index] = preset
            } else {
                state.routingProfiles.insert(preset, at: 0)
            }
        }
        if state.activeRoutingName == nil || !state.routingProfiles.contains(where: { $0.name == state.activeRoutingName }) {
            state.activeRoutingName = RoutingPresets.smartName
        }
    }

    // MARK: - Lookups

    func server(_ id: UUID) -> ServerNode? { state.servers.first { $0.id == id } }

    func servers(in group: UUID) -> [ServerNode] { state.servers.filter { $0.groupID == group } }

    func subscription(_ id: UUID?) -> ProxySubscription? {
        guard let id else { return nil }
        return state.subscriptions.first { $0.id == id }
    }

    func groupTitle(_ id: UUID) -> String {
        id == ServerGroup.manualID ? "Мои серверы" : (subscription(id)?.name ?? "Группа")
    }

    var activeGroupID: UUID? {
        switch state.selection {
        case .none: return nil
        case .server(let id): return server(id)?.groupID
        case .auto(let group): return group
        }
    }

    var activeProfile: RoutingProfile? {
        state.routingProfiles.first { $0.name == state.activeRoutingName }
    }

    var selectionTitle: String {
        switch state.selection {
        case .none: return "Сервер не выбран"
        case .server(let id): return server(id)?.name ?? "Сервер удалён"
        case .auto(let group): return "Автовыбор · \(groupTitle(group))"
        }
    }

    func sortedServers(in group: UUID) -> [ServerNode] {
        let list = servers(in: group)
        switch effectiveSettings(for: group).sortOrder {
        case .none:
            return list
        case .alphabet:
            return list.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .ping:
            return list.sorted { Self.rank($0.latency) < Self.rank($1.latency) }
        }
    }

    private static func rank(_ latency: Int?) -> Int {
        guard let latency else { return Int.max - 1 }
        return latency < 0 ? Int.max : latency
    }

    /// Fastest alive servers of a group (by the last test); falls back to list order.
    func autoCandidates(group: UUID, count: Int) -> [ServerNode] {
        let list = servers(in: group)
        let alive = list.filter { ($0.latency ?? -1) > 0 }.sorted { ($0.latency ?? 0) < ($1.latency ?? 0) }
        let limit = max(1, min(count, 20))
        return Array((alive.isEmpty ? list : alive).prefix(limit))
    }

    func effectiveSettings(for group: UUID?) -> EffectiveSettings {
        let s = state.settings
        let o = subscription(group)?.options ?? ProviderOptions()
        var fragment = s.fragment
        if let enabled = o.fragmentation { fragment.enabled = enabled }
        if let value = o.fragmentPackets { fragment.packets = value }
        if let value = o.fragmentLength { fragment.length = value }
        if let value = o.fragmentInterval { fragment.interval = value }
        if let value = o.fragmentMaxSplit { fragment.maxSplit = value }
        return EffectiveSettings(
            pingType: o.pingType ?? s.pingType,
            testURL: o.checkURL ?? s.testURL,
            pingTimeout: o.pingTimeout ?? s.pingTimeout,
            pingConcurrency: s.pingConcurrency,
            autoTopK: s.autoTopK,
            autoProbeMinutes: s.autoProbeMinutes,
            sniffing: o.sniffing ?? s.sniffing,
            mux: o.mux ?? s.mux,
            fragment: fragment,
            enableIPv6: s.enableIPv6,
            mtu: o.mtu ?? s.mtu,
            excludeLocalNetworks: o.excludeLocalNetworks ?? s.excludeLocalNetworks,
            includeAllNetworks: o.includeAllNetworks ?? s.includeAllNetworks,
            excludeAPNs: o.excludeAPNs ?? s.excludeAPNs,
            logLevel: s.logLevel,
            routingEnabled: state.routingEnabled,
            sortOrder: o.sortOrder ?? s.sortOrder)
    }

    // MARK: - Lifecycle

    func bootstrap() async {
        guard !bootstrapped else { return }
        bootstrapped = true
        coreVersion = await sandbox.version()
        await vpn.load()
        startPolling()

        let updateAll = state.settings.updateSubscriptionsOnOpen
            || state.subscriptions.contains { $0.options.autoUpdateOnOpen == true }
        await updateSubscriptions(onlyDue: !updateAll)
        Task { await self.ensureGeoFiles(force: false) }

        let group = activeGroupID ?? state.subscriptions.first?.id
        let options = subscription(group)?.options
        let autoConnect = options?.autoConnect ?? state.settings.autoConnectOnLaunch
        if autoConnect, !vpn.isActive {
            if let group { applyAutoConnectType(options?.autoConnectType, group: group) }
            await connect()
        } else if let group, options?.pingOnOpen ?? state.settings.pingOnOpen, !vpn.isActive {
            await testLatency(group: group)
        }
    }

    func didBecomeActive() async {
        guard bootstrapped else { return }
        await updateSubscriptions(onlyDue: true)
    }

    private func applyAutoConnectType(_ type: String?, group: UUID) {
        switch type ?? "" {
        case "lowestdelay":
            state.selection = .auto(group)
        case "random":
            if let random = servers(in: group).randomElement() { state.selection = .server(random.id) }
        default:
            if state.selection == .none { state.selection = .auto(group) }
        }
    }

    // MARK: - Connection

    func toggleConnection() async {
        if vpn.isActive || vpn.status == .disconnecting {
            await vpn.stop()
        } else {
            await connect()
        }
    }

    func connect() async {
        guard !isConnecting else { return }
        isConnecting = true
        defer { isConnecting = false }
        do {
            try ensureSelection()
            if case .auto(let group) = state.selection, needsFreshTest(group) {
                await testLatency(group: group)
            }
            if state.routingEnabled, let profile = activeProfile, profile.needsGeo,
               !(GeoFiles.hasGeoIP && GeoFiles.hasGeoSite) {
                await ensureGeoFiles(force: false)
            }
            let plan = try await makeValidatedPlan()
            try await vpn.start(plan: plan, settings: effectiveSettings(for: activeGroupID), onDemand: state.settings.onDemand)
            if case .server(let id) = state.selection { state.lastUsedServer = id }
            scheduleSave()
        } catch {
            show(error.localizedDescription, error: true)
        }
    }

    func select(_ selection: ServerSelection) async {
        guard state.selection != selection else { return }
        state.selection = selection
        if case .server(let id) = selection { state.lastUsedServer = id }
        scheduleSave()
        await applyIfConnected()
    }

    func applyIfConnected() async {
        guard vpn.isConnected else { return }
        do {
            let plan = try await makeValidatedPlan()
            try await vpn.apply(plan: plan, settings: effectiveSettings(for: activeGroupID), onDemand: state.settings.onDemand)
        } catch {
            show(error.localizedDescription, error: true)
        }
    }

    private func ensureSelection() throws {
        switch state.selection {
        case .server(let id) where server(id) != nil:
            return
        case .auto(let group) where !servers(in: group).isEmpty:
            return
        default:
            if let group = state.subscriptions.first(where: { !servers(in: $0.id).isEmpty })?.id {
                state.selection = .auto(group)
            } else if let first = servers(in: ServerGroup.manualID).first {
                state.selection = .server(first.id)
            } else {
                throw ConfigError.noServers
            }
        }
    }

    private func needsFreshTest(_ group: UUID) -> Bool {
        let tested = servers(in: group).compactMap(\.testedAt)
        guard let latest = tested.max() else { return true }
        return Date().timeIntervalSince(latest) > 600
    }

    func makePlan(stripGeo: Bool) throws -> TunnelPlan {
        let group = activeGroupID
        let settings = effectiveSettings(for: group)
        let mode: BuildMode
        let title: String
        switch state.selection {
        case .none:
            throw ConfigError.noServers
        case .server(let id):
            guard let node = server(id) else { throw ConfigError.noServers }
            mode = .single(node)
            title = node.name
        case .auto(let group):
            let candidates = autoCandidates(group: group, count: settings.autoTopK)
            guard !candidates.isEmpty else { throw ConfigError.noServers }
            mode = .auto(candidates)
            title = "Автовыбор · \(groupTitle(group))"
        }
        let testServers = group.map { Array(servers(in: $0).prefix(150)) } ?? []
        let input = BuildInput(
            mode: mode,
            testServers: testServers,
            profile: state.routingEnabled ? activeProfile : nil,
            settings: settings,
            hasGeoIP: GeoFiles.hasGeoIP,
            hasGeoSite: GeoFiles.hasGeoSite,
            stripGeo: stripGeo,
            logPath: Store.xrayLogURL.path,
            title: title)
        return try ConfigBuilder.tunnelPlan(input)
    }

    /// Builds the config and checks it with the real core (testXray). If geo categories are missing
    /// from the downloaded files, falls back to a config without geoip/geosite rules.
    func makeValidatedPlan() async throws -> TunnelPlan {
        var plan = try makePlan(stripGeo: false)
        let stripped = try? makePlan(stripGeo: true)
        do {
            try await sandbox.validate(plan)
            if let stripped, stripped.configJSON != plan.configJSON {
                plan.fallbackConfigJSON = stripped.configJSON
            }
            return plan
        } catch {
            let message = error.localizedDescription
            AppLog.write("Проверка конфигурации: \(message)")
            guard let fallback = stripped, fallback.configJSON != plan.configJSON else {
                throw ConfigError.invalid(message)
            }
            do {
                try await sandbox.validate(fallback)
            } catch {
                throw ConfigError.invalid(message)
            }
            show("Правила geoip/geosite временно отключены: \(message). Обновите гео-файлы.", error: true)
            return fallback
        }
    }

    // MARK: - Latency

    func testLatency(group: UUID) async {
        guard !testingGroups.contains(group) else { return }
        let list = servers(in: group)
        guard !list.isEmpty else { return }
        testingGroups.insert(group)
        defer { testingGroups.remove(group) }
        let settings = effectiveSettings(for: group)
        var results: [UUID: Int] = [:]

        // While connected, test from inside the tunnel extension: its traffic bypasses the tunnel,
        // so numbers are not distorted by the current proxy.
        if vpn.isConnected, let plan = vpn.activePlan {
            let inTunnel = Set(plan.testInbounds.values)
            let ids = list.map(\.id).filter { settings.pingType == .tcp || inTunnel.contains($0) }
            if !ids.isEmpty, let remote = try? await vpn.ping(ids: ids, settings: settings) {
                results.merge(remote) { _, new in new }
            }
        }
        let remaining = list.filter { results[$0.id] == nil }
        if !remaining.isEmpty {
            let local = await sandbox.latency(servers: remaining, settings: settings)
            results.merge(local) { _, new in new }
        }
        let now = Date()
        for index in state.servers.indices {
            if let value = results[state.servers[index].id] {
                state.servers[index].latency = value
                state.servers[index].testedAt = now
            }
        }
        scheduleSave()
    }

    func testAll() async {
        var groups = state.subscriptions.map(\.id)
        if !servers(in: ServerGroup.manualID).isEmpty { groups.append(ServerGroup.manualID) }
        for group in groups { await testLatency(group: group) }
    }

    // MARK: - Import

    /// Universal import: subscription URL, share links, Base64, Xray JSON, happ:// deep links.
    func importText(_ raw: String) async {
        let text = raw.trimmed
        guard !text.isEmpty else { return }
        let lower = text.lowercased()
        if lower.contains("://routing/") || lower.contains("://autorouting/") {
            await importRoutingLink(text)
            return
        }
        if lower.hasPrefix("happ://crypt") {
            show("Зашифрованные ссылки Happ не поддерживаются. Попросите у провайдера обычную ссылку подписки.", error: true)
            return
        }
        for prefix in ["strela://add/", "happ://add/", "v2raytun://import/", "hiddify://import/", "streisand://import/"]
        where lower.hasPrefix(prefix) {
            let rest = String(text.dropFirst(prefix.count))
            await addSubscription(url: rest.removingPercentEncoding ?? rest)
            return
        }
        if !text.contains("\n"), lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            await addSubscription(url: text)
            return
        }
        let parsed = await Task.detached(priority: .userInitiated) {
            ShareLinks.parse(text: text, groupID: ServerGroup.manualID)
        }.value
        for link in parsed.meta.routingLinks { await importRoutingLink(link) }
        guard !parsed.nodes.isEmpty else {
            if parsed.meta.routingLinks.isEmpty {
                show("Не найдено поддерживаемых конфигураций", error: true)
            }
            return
        }
        state.servers.append(contentsOf: parsed.nodes)
        if state.selection == .none, let first = parsed.nodes.first { state.selection = .server(first.id) }
        scheduleSave()
        var message = "Добавлено серверов: \(parsed.nodes.count)"
        if parsed.failed > 0 { message += ", пропущено: \(parsed.failed)" }
        show(message, error: false)
    }

    func handleOpenURL(_ url: URL) async {
        if url.scheme?.lowercased() == "strela" {
            switch url.host?.lowercased() {
            case "connect":
                if !vpn.isActive { await connect() }
                return
            case "disconnect":
                await vpn.stop()
                return
            case "toggle":
                await toggleConnection()
                return
            default:
                break
            }
        }
        await importText(url.absoluteString)
    }

    // MARK: - Subscriptions

    func addSubscription(url raw: String, name: String? = nil) async {
        let urlString = raw.trimmed
        guard let url = URL(string: urlString), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            show("Некорректная ссылка подписки", error: true)
            return
        }
        if let existing = state.subscriptions.first(where: { $0.url == urlString }) {
            await updateSubscription(existing.id)
            return
        }
        var subscription = ProxySubscription(name: name?.nonEmpty ?? (url.host ?? "Подписка"), url: urlString)
        subscription.nameLocked = name?.nonEmpty != nil
        state.subscriptions.append(subscription)
        scheduleSave()
        await updateSubscription(subscription.id)
        if state.selection == .none, !servers(in: subscription.id).isEmpty {
            state.selection = .auto(subscription.id)
            scheduleSave()
        }
    }

    func updateSubscriptions(onlyDue: Bool) async {
        let targets = state.subscriptions.filter { !onlyDue || $0.isDue }.map(\.id)
        await withTaskGroup(of: Void.self) { group in
            for id in targets {
                group.addTask { await self.updateSubscription(id) }
            }
        }
    }

    func updateSubscription(_ id: UUID) async {
        guard let current = subscription(id), !updatingSubscriptions.contains(id) else { return }
        updatingSubscriptions.insert(id)
        defer { updatingSubscriptions.remove(id) }
        let keys = ageKeys()
        do {
            let result = try await SubscriptionService.fetch(current, settings: state.settings,
                                                             agePublicKey: keys.publicKey, ageSecretKey: keys.secretKey)
            await apply(result, to: id)
        } catch {
            if let index = state.subscriptions.firstIndex(where: { $0.id == id }) {
                state.subscriptions[index].lastError = error.localizedDescription
            }
            show("\(current.name): \(error.localizedDescription)", error: true)
        }
        scheduleSave()
    }

    private func apply(_ result: SubscriptionFetchResult, to id: UUID) async {
        guard let index = state.subscriptions.firstIndex(where: { $0.id == id }) else { return }
        var subscription = state.subscriptions[index]
        let meta = result.meta
        if !subscription.nameLocked, let title = meta.title?.nonEmpty { subscription.name = String(title.prefix(40)) }
        if let info = meta.userInfo { subscription.userInfo = info }
        subscription.updateIntervalHours = meta.updateInterval
        subscription.supportURL = meta.supportURL
        subscription.webPageURL = meta.webPageURL
        subscription.announce = meta.announce
        subscription.options = meta.options
        subscription.isJSON = result.isJSON
        if let newURL = meta.newURL?.nonEmpty, URL(string: newURL) != nil { subscription.url = newURL }
        if let fallback = meta.fallbackURL?.nonEmpty { subscription.fallbackURL = fallback }
        subscription.lastUpdated = Date()
        subscription.lastError = nil
        state.subscriptions[index] = subscription

        // Keep ids and latency of servers that did not change, so the selection survives updates.
        let old = servers(in: id)
        var byKey: [String: ServerNode] = [:]
        var byName: [String: ServerNode] = [:]
        for server in old {
            byKey[server.identityKey] = server
            byName[server.name] = server
        }
        var used = Set<UUID>()
        var merged: [ServerNode] = []
        for var node in result.nodes {
            if let previous = byKey[node.identityKey] ?? byName[node.name], !used.contains(previous.id) {
                node.id = previous.id
                node.latency = previous.latency
                node.testedAt = previous.testedAt
            }
            used.insert(node.id)
            merged.append(node)
        }
        state.servers.removeAll { $0.groupID == id }
        state.servers.append(contentsOf: merged)
        if case .server(let selected) = state.selection, !state.servers.contains(where: { $0.id == selected }) {
            state.selection = .auto(id)
        }
        if let enabled = meta.routingEnabled { state.routingEnabled = enabled }
        for link in meta.routingLinks { await importRoutingLink(link, subscription: id, quiet: true) }
        scheduleSave()
    }

    func renameSubscription(_ id: UUID, to name: String) {
        guard let index = state.subscriptions.firstIndex(where: { $0.id == id }), let name = name.nonEmpty else { return }
        state.subscriptions[index].name = name
        state.subscriptions[index].nameLocked = true
        scheduleSave()
    }

    func deleteSubscription(_ id: UUID) {
        state.subscriptions.removeAll { $0.id == id }
        state.servers.removeAll { $0.groupID == id }
        if activeGroupID == nil { state.selection = .none }
        scheduleSave()
    }

    func deleteServer(_ id: UUID) {
        state.servers.removeAll { $0.id == id }
        if case .server(let selected) = state.selection, selected == id { state.selection = .none }
        scheduleSave()
    }

    func shareLink(for server: ServerNode) -> String? {
        if let link = server.link { return link }
        guard var outbound = JSONUtil.object(server.outbound) else { return nil }
        outbound["tag"] = server.name
        return try? XrayCore.shareLinks(for: [outbound]).nonEmpty
    }

    private func ageKeys() -> (publicKey: String?, secretKey: String?) {
        guard state.settings.ageEncryption else { return (nil, nil) }
        if state.agePublicKey == nil || state.ageSecretKey == nil, let pair = try? XrayCore.generateAgeKeyPair() {
            state.ageSecretKey = pair.secretKey
            state.agePublicKey = pair.publicKey
            scheduleSave()
        }
        return (state.agePublicKey, state.ageSecretKey)
    }

    // MARK: - Routing

    func importRoutingLink(_ link: String, subscription: UUID? = nil, quiet: Bool = false) async {
        guard let action = HappRouting.parse(link: link) else {
            if !quiet { show("Не удалось разобрать профиль маршрутизации", error: true) }
            return
        }
        switch action {
        case .off:
            state.routingEnabled = false
            if !quiet { show("Маршрутизация выключена", error: false) }
            await applyIfConnected()
        case .remote(let urlString, let activate):
            guard let url = URL(string: urlString) else { return }
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                guard let profile = HappRouting.profile(fromPayload: String(decoding: data, as: UTF8.self)) else {
                    throw ConfigError.invalid("профиль маршрутизации")
                }
                await addRoutingProfile(profile, activate: activate, subscription: subscription, quiet: quiet)
            } catch {
                if !quiet { show("Профиль маршрутизации: \(error.localizedDescription)", error: true) }
            }
        case .add(let profile, let activate):
            await addRoutingProfile(profile, activate: activate, subscription: subscription, quiet: quiet)
        }
        scheduleSave()
    }

    private func addRoutingProfile(_ incoming: RoutingProfile, activate: Bool, subscription: UUID?, quiet: Bool) async {
        var profile = incoming
        profile.isBuiltIn = false
        profile.subscriptionID = subscription
        if RoutingPresets.builtInNames.contains(profile.name) { profile.name += " (импорт)" }
        let existing = state.routingProfiles.firstIndex { $0.name == profile.name }
        let changed = existing.map { state.routingProfiles[$0] != profile } ?? true
        if let existing {
            state.routingProfiles[existing] = profile
        } else {
            state.routingProfiles.append(profile)
        }
        // `onadd` activates new/changed profiles; `add` only when the user has not picked one manually.
        let shouldActivate = (activate && changed) || (!activate && existing == nil && !state.userPickedRouting)
        if shouldActivate {
            state.activeRoutingName = profile.name
            state.routingEnabled = true
            scheduleSave()
            await ensureGeoFiles(force: false)
            await applyIfConnected()
        } else if state.activeRoutingName == profile.name, changed {
            await applyIfConnected()
        }
        if !quiet { show("Профиль «\(profile.name)» добавлен", error: false) }
    }

    func activateRouting(_ name: String) async {
        state.activeRoutingName = name
        state.routingEnabled = true
        state.userPickedRouting = true
        scheduleSave()
        await ensureGeoFiles(force: false)
        await applyIfConnected()
    }

    func saveRouting(_ profile: RoutingProfile, replacing originalName: String?) async {
        var updated = profile
        updated.isBuiltIn = false
        if let originalName, let index = state.routingProfiles.firstIndex(where: { $0.name == originalName }),
           !state.routingProfiles[index].isBuiltIn {
            state.routingProfiles[index] = updated
            if state.activeRoutingName == originalName { state.activeRoutingName = updated.name }
        } else {
            while state.routingProfiles.contains(where: { $0.name == updated.name }) { updated.name += " (копия)" }
            state.routingProfiles.append(updated)
        }
        scheduleSave()
        if state.activeRoutingName == updated.name { await applyIfConnected() }
    }

    func deleteRouting(_ name: String) {
        state.routingProfiles.removeAll { $0.name == name && !$0.isBuiltIn }
        if state.activeRoutingName == name { state.activeRoutingName = RoutingPresets.smartName }
        scheduleSave()
    }

    func routingToggled() async {
        scheduleSave()
        await applyIfConnected()
    }

    func ensureGeoFiles(force: Bool) async {
        guard let profile = activeProfile, force || (state.routingEnabled && profile.needsGeo) else { return }
        let fresh = state.geo.sourceKey == profile.geoKey && GeoFiles.hasGeoIP && GeoFiles.hasGeoSite
            && (state.geo.updatedAt.map { Date().timeIntervalSince($0) < 7 * 86400 } ?? false)
        guard force || !fresh, !geoBusy else { return }
        geoBusy = true
        defer { geoBusy = false }
        do {
            try await GeoFiles.download(geoip: profile.geoipURL, geosite: profile.geositeURL)
            state.geo = GeoState(sourceKey: profile.geoKey, updatedAt: Date())
            scheduleSave()
            if force { show("Гео-файлы обновлены", error: false) }
            await applyIfConnected()
        } catch {
            show("Гео-файлы: \(error.localizedDescription)", error: true)
        }
    }

    // MARK: - Status polling

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { return }
                await self.poll()
            }
        }
    }

    private func poll() async {
        guard vpn.isConnected, isForeground else {
            if tunnelStatus != nil || speedUp != 0 || speedDown != 0 {
                tunnelStatus = nil
                speedUp = 0
                speedDown = 0
            }
            lastSample = nil
            return
        }
        guard let status = try? await vpn.tunnelStatus() else { return }
        let now = Date()
        if let last = lastSample {
            let interval = now.timeIntervalSince(last.date)
            if interval > 0 {
                speedUp = Double(max(0, status.uplink - last.up)) / interval
                speedDown = Double(max(0, status.downlink - last.down)) / interval
            }
        }
        lastSample = (now, status.uplink, status.downlink)
        tunnelStatus = status
    }

    // MARK: - Persistence & banners

    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let self, !Task.isCancelled else { return }
            Store.saveState(self.state)
        }
    }

    func show(_ text: String, error: Bool) {
        banner = Banner(text: text, isError: error)
        bannerTask?.cancel()
        bannerTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: error ? 6_000_000_000 : 3_000_000_000)
            guard !Task.isCancelled else { return }
            self?.banner = nil
        }
    }

    func resetAll() async {
        await vpn.stop()
        await vpn.removeConfiguration()
        var fresh = AppState()
        Self.ensureBuiltInProfiles(&fresh)
        state = fresh
        Store.saveState(state)
        show("Все данные сброшены", error: false)
    }
}
