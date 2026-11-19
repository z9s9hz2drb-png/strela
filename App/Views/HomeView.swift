import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                if let profile = ProvisioningProfile.embedded, !profile.hasNetworkExtension {
                    SigningWarningCard(profile: profile)
                }
                ConnectButton()
                    .padding(.top, 12)
                SelectionCard()
                if model.vpn.isConnected {
                    TrafficCard()
                }
                RoutingCard()
                if let group = model.activeGroupID, let subscription = model.subscription(group) {
                    SubscriptionCard(subscription: subscription)
                }
            }
            .padding()
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Подключение")
    }
}

struct ConnectButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let status = model.vpn.status
        let connected = status == .connected
        let busy = model.isConnecting || model.vpn.isBusy
        VStack(spacing: 12) {
            Button {
                Task { await model.toggleConnection() }
            } label: {
                ZStack {
                    Circle()
                        .fill(connected
                              ? AnyShapeStyle(LinearGradient(colors: [.green, .teal], startPoint: .topLeading, endPoint: .bottomTrailing))
                              : AnyShapeStyle(Color(uiColor: .secondarySystemGroupedBackground)))
                    Circle()
                        .stroke(connected ? Color.white.opacity(0.35) : Color.accentColor.opacity(0.35), lineWidth: 6)
                        .padding(10)
                    Image(systemName: "power")
                        .font(.system(size: 58, weight: .semibold))
                        .foregroundStyle(connected ? Color.white : Color.accentColor)
                    if busy {
                        ProgressView()
                            .controlSize(.large)
                            .tint(connected ? .white : .accentColor)
                            .offset(y: 58)
                    }
                }
                .frame(width: 180, height: 180)
                .shadow(color: connected ? Color.green.opacity(0.45) : Color.black.opacity(0.08), radius: connected ? 28 : 10)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(connected ? "Отключить" : "Подключить")

            Text(StatusText.title(status, preparing: model.isConnecting))
                .font(.title3.weight(.semibold))
            if connected, let since = model.vpn.connectedDate {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(Format.duration(from: since, to: context.date))
                        .font(.body.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: connected)
    }
}

struct SelectionCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Card {
            HStack(alignment: .firstTextBaseline) {
                Text("Сервер").font(.headline)
                Spacer()
                if let group = model.activeGroupID {
                    Picker("Режим", selection: Binding(
                        get: { modeIndex },
                        set: { value in
                            Task {
                                switch value {
                                case 1:
                                    await model.select(.auto(group))
                                case 2:
                                    await model.select(.fastest(group))
                                default:
                                    if let best = model.autoCandidates(group: group, count: 1).first {
                                        await model.select(.server(best.id))
                                    }
                                }
                            }
                        }
                    )) {
                        Text("Вручную").tag(0)
                        Text("Пинг").tag(1)
                        Text("Скорость").tag(2)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 320)
                }
            }
            switch model.state.selection {
            case .none:
                Text("Добавьте подписку или сервер на вкладке «Серверы».")
                    .foregroundStyle(.secondary)
            case .server(let id):
                if let server = model.server(id) {
                    ServerSummary(name: server.name, subtitle: server.subtitle, latency: server.latency)
                } else {
                    Text("Сервер удалён — выберите другой").foregroundStyle(.secondary)
                }
            case .auto(let group):
                autoSummary(group)
            case .fastest(let group):
                speedSummary(group)
            }
        }
    }

    private var modeIndex: Int {
        switch model.state.selection {
        case .auto: return 1
        case .fastest: return 2
        default: return 0
        }
    }

    @ViewBuilder
    private func speedSummary(_ group: UUID) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Самый быстрый по скорости · \(model.groupTitle(group))", systemImage: "speedometer")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.tint)
                Spacer()
                if model.speedTestingGroups.contains(group) {
                    ProgressView()
                } else {
                    Button("Тест скорости") {
                        Task { await model.testSpeed(group: group) }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            if let progress = model.speedProgress, model.speedTestingGroups.contains(group) {
                Text(progress).font(.caption).foregroundStyle(.secondary)
            }
            if model.vpn.isConnected, let status = model.tunnelStatus, let tag = status.activeAutoTag,
               let name = status.tagNames[tag] {
                let speed = model.servers(in: group).first { $0.name == name }?.speedMbps
                ServerSummary(name: name,
                              subtitle: "Сейчас используется" + (speed.map { $0 > 0 ? " · \(AppModel.formatMbps($0))" : "" } ?? ""),
                              latency: status.observatory[tag].map { Int($0.delay) })
            } else if let best = model.speedCandidates(group: group, count: 1).first, let mbps = best.speedMbps {
                ServerSummary(name: best.name, subtitle: "Самый быстрый по последнему тесту · \(AppModel.formatMbps(mbps))",
                              latency: best.latency)
            } else {
                Text("Скорость ещё не измерялась: тест запустится при подключении.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("Лучшие по пингу серверы по очереди скачивают тестовый файл (до \(model.state.settings.speedTestSeconds) с каждый). Подключение идёт к самому быстрому; если он перестаёт отвечать на GET-проверки, трафик переходит на следующий по скорости.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func autoSummary(_ group: UUID) -> some View {
        let pingTitle = model.effectiveSettings(for: group).pingType.title
        VStack(alignment: .leading, spacing: 6) {
            Label("Автовыбор по \(pingTitle) · \(model.groupTitle(group))", systemImage: "bolt.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.tint)
            if model.vpn.isConnected, let status = model.tunnelStatus, let tag = status.activeAutoTag {
                let delay = status.observatory[tag].map { Int($0.delay) }
                ServerSummary(name: status.tagNames[tag] ?? tag, subtitle: "Сейчас используется (observatory, GET)", latency: delay)
            } else if let best = model.autoCandidates(group: group, count: 1).first {
                ServerSummary(name: best.name, subtitle: "Лучший по последнему тесту", latency: best.latency)
            }
            Text("Балансировщик leastPing проверяет кандидатов запросом GET каждые \(model.state.settings.autoProbeMinutes) мин и переключается на самый быстрый, если сервер упал.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct ServerSummary: View {
    let name: String
    let subtitle: String
    let latency: Int?

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(.body.weight(.medium)).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            LatencyBadge(ms: latency)
        }
    }
}

struct TrafficCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Card {
            Text("Трафик").font(.headline)
            HStack(spacing: 24) {
                metric(icon: "arrow.up", title: "Отдача", value: Format.speed(model.speedUp), total: model.tunnelStatus?.uplink)
                metric(icon: "arrow.down", title: "Загрузка", value: Format.speed(model.speedDown), total: model.tunnelStatus?.downlink)
            }
            if let status = model.tunnelStatus {
                Divider()
                HStack {
                    Label("Через VPN: \(Format.bytes(status.proxyUplink + status.proxyDownlink))", systemImage: "lock.shield")
                    Spacer()
                    Label("Напрямую: \(Format.bytes(status.directUplink + status.directDownlink))", systemImage: "arrow.right")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func metric(icon: String, title: String, value: String, total: Int64?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: icon).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.monospacedDigit().weight(.semibold))
            if let total {
                Text("всего \(Format.bytes(total))").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

struct RoutingCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Card {
            HStack {
                Text("Маршрутизация").font(.headline)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { model.state.routingEnabled },
                    set: { value in
                        model.state.routingEnabled = value
                        Task { await model.routingToggled() }
                    }
                ))
                .labelsHidden()
            }
            Menu {
                ForEach(model.state.routingProfiles) { profile in
                    Button {
                        Task { await model.activateRouting(profile.name) }
                    } label: {
                        if profile.name == model.state.activeRoutingName {
                            Label(profile.name, systemImage: "checkmark")
                        } else {
                            Text(profile.name)
                        }
                    }
                }
            } label: {
                HStack {
                    Text(model.state.routingEnabled ? (model.state.activeRoutingName ?? "—") : "Выключена: всё через VPN")
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down").foregroundStyle(.secondary)
                }
                .padding(12)
                .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
            }
            .disabled(!model.state.routingEnabled)
            if model.geoBusy {
                ProgressView("Загрузка гео-файлов…").font(.caption)
            }
        }
    }
}

struct SubscriptionCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    let subscription: ProxySubscription

    var body: some View {
        Card {
            HStack {
                Text(subscription.name).font(.headline).lineLimit(1)
                Spacer()
                if model.updatingSubscriptions.contains(subscription.id) {
                    ProgressView()
                } else {
                    Button {
                        Task { await model.updateSubscription(subscription.id) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                }
            }
            if let info = subscription.userInfo {
                UsageView(info: info)
            }
            if let announce = subscription.announce?.nonEmpty {
                Label(announce, systemImage: "megaphone")
                    .font(.callout)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            }
            HStack {
                if let support = subscription.supportURL.flatMap(URL.init(string:)) {
                    Button { openURL(support) } label: { Label("Поддержка", systemImage: "questionmark.bubble") }
                        .buttonStyle(.bordered)
                }
                if let page = subscription.webPageURL.flatMap(URL.init(string:)) {
                    Button { openURL(page) } label: { Label("Сайт", systemImage: "globe") }
                        .buttonStyle(.bordered)
                }
                Spacer()
                if let updated = subscription.lastUpdated {
                    Text("обновлено \(updated.formatted(.relative(presentation: .named)))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct UsageView: View {
    let info: SubscriptionUserInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if info.total > 0 {
                ProgressView(value: min(1, Double(info.used) / Double(info.total)))
                    .tint(Double(info.used) / Double(info.total) > 0.9 ? .red : .accentColor)
                Text("\(Format.bytes(info.used)) из \(Format.bytes(info.total))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Использовано \(Format.bytes(info.used)) · без лимита")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let expire = info.expire {
                let days = info.daysLeft ?? 0
                Text(days >= 0 ? "Активна до \(Format.date(expire)) · осталось \(days) дн." : "Подписка истекла \(Format.date(expire))")
                    .font(.caption)
                    .foregroundStyle(days < 3 ? Color.red : Color.secondary)
            }
        }
    }
}

/// Shown when the app was re-signed (GBox, ESign…) with a profile that has no VPN entitlement.
struct SigningWarningCard: View {
    let profile: ProvisioningProfile

    var body: some View {
        Card {
            Label("Подпись не поддерживает VPN", systemImage: "exclamationmark.shield.fill")
                .font(.headline)
                .foregroundStyle(.red)
            Text("В профиле подписи\(profile.teamName.map { " «\($0)»" } ?? "") нет права Network Extension, поэтому iOS не даст включить VPN. Переподпишите IPA в GBox сертификатом с поддержкой VPN (Network Extension и App Groups).")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}
