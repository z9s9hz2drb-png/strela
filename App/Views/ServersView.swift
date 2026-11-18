import SwiftUI
import UIKit

struct ServersView: View {
    @Environment(AppModel.self) private var model
    @State private var showAdd = false
    @State private var qrItem: QRItem?

    var body: some View {
        List {
            if model.state.subscriptions.isEmpty && model.servers(in: ServerGroup.manualID).isEmpty {
                ContentUnavailableView {
                    Label("Нет серверов", systemImage: "server.rack")
                } description: {
                    Text("Добавьте ссылку подписки, конфигурацию vless/vmess/trojan/ss/hy2, JSON Xray или отсканируйте QR-код.")
                } actions: {
                    Button("Добавить") { showAdd = true }.buttonStyle(.borderedProminent)
                }
            }
            ForEach(model.state.subscriptions) { subscription in
                Section {
                    GroupRows(group: subscription.id,
                              hideSettings: subscription.options.hideSettings == true,
                              onShowQR: { qrItem = $0 })
                } header: {
                    SubscriptionHeader(subscription: subscription, onShowQR: { qrItem = $0 })
                }
            }
            if !model.servers(in: ServerGroup.manualID).isEmpty {
                Section {
                    GroupRows(group: ServerGroup.manualID, hideSettings: false, onShowQR: { qrItem = $0 })
                } header: {
                    HStack {
                        Text("Мои серверы")
                        Spacer()
                        TestButton(group: ServerGroup.manualID)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Серверы")
        .refreshable { await model.updateSubscriptions(onlyDue: false) }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    Task { await model.testAll() }
                } label: {
                    Label("Тест всех", systemImage: "bolt.horizontal")
                }
                .disabled(!model.testingGroups.isEmpty)
                Menu {
                    Picker("Сортировка", selection: Binding(
                        get: { model.state.settings.sortOrder },
                        set: { model.state.settings.sortOrder = $0; model.scheduleSave() }
                    )) {
                        ForEach(ServerSortOrder.allCases) { order in Text(order.title).tag(order) }
                    }
                    Button {
                        Task { await model.updateSubscriptions(onlyDue: false) }
                    } label: {
                        Label("Обновить все подписки", systemImage: "arrow.clockwise")
                    }
                } label: {
                    Label("Ещё", systemImage: "ellipsis.circle")
                }
                Button {
                    showAdd = true
                } label: {
                    Label("Добавить", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showAdd) { AddSheet() }
        .sheet(item: $qrItem) { QRCodeSheet(item: $0) }
    }
}

struct TestButton: View {
    @Environment(AppModel.self) private var model
    let group: UUID

    var body: some View {
        if model.testingGroups.contains(group) {
            ProgressView()
        } else {
            Button {
                Task { await model.testLatency(group: group) }
            } label: {
                Label("Тест", systemImage: "bolt")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
        }
    }
}

struct GroupRows: View {
    @Environment(AppModel.self) private var model
    let group: UUID
    let hideSettings: Bool
    let onShowQR: (QRItem) -> Void

    var body: some View {
        let servers = model.sortedServers(in: group)
        if servers.count > 1 {
            AutoRow(group: group)
        }
        ForEach(servers) { server in
            ServerRow(server: server, selected: model.state.selection == .server(server.id))
                .contentShape(Rectangle())
                .onTapGesture {
                    Task { await model.select(.server(server.id)) }
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        model.deleteServer(server.id)
                    } label: {
                        Label("Удалить", systemImage: "trash")
                    }
                }
                .contextMenu {
                    Button {
                        Task { await model.select(.server(server.id)) }
                    } label: {
                        Label("Выбрать", systemImage: "checkmark.circle")
                    }
                    if !hideSettings, let link = model.shareLink(for: server) {
                        Button {
                            UIPasteboard.general.string = link
                            model.show("Ссылка скопирована", error: false)
                        } label: {
                            Label("Скопировать ссылку", systemImage: "doc.on.doc")
                        }
                        Button {
                            onShowQR(QRItem(title: server.name, text: link))
                        } label: {
                            Label("QR-код", systemImage: "qrcode")
                        }
                    }
                    Button(role: .destructive) {
                        model.deleteServer(server.id)
                    } label: {
                        Label("Удалить", systemImage: "trash")
                    }
                }
        }
    }
}

struct AutoRow: View {
    @Environment(AppModel.self) private var model
    let group: UUID

    var body: some View {
        let selected = model.state.selection == .auto(group)
        let best = model.autoCandidates(group: group, count: 1).first
        let pingTitle = model.effectiveSettings(for: group).pingType.title
        HStack(spacing: 12) {
            Image(systemName: selected ? "bolt.circle.fill" : "bolt.circle")
                .font(.title3)
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Автовыбор — лучший по \(pingTitle)")
                    .fontWeight(.medium)
                Text(subtitle(best))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if model.testingGroups.contains(group) {
                ProgressView()
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture {
            Task { await model.select(.auto(group)) }
        }
    }

    private func subtitle(_ best: ServerNode?) -> String {
        guard let best, let latency = best.latency, latency > 0 else {
            return "нажмите ⚡, чтобы проверить серверы"
        }
        return "сейчас лучший: \(best.name) · \(latency) мс"
    }
}

struct ServerRow: View {
    let server: ServerNode
    let selected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(selected ? Color.accentColor : Color.secondary.opacity(0.6))
            VStack(alignment: .leading, spacing: 2) {
                Text(server.name).lineLimit(1)
                Text(server.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            LatencyBadge(ms: server.latency)
        }
        .padding(.vertical, 2)
    }
}

struct SubscriptionHeader: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    let subscription: ProxySubscription
    let onShowQR: (QRItem) -> Void
    @State private var renaming = false
    @State private var newName = ""
    @State private var confirmDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Text(subscription.name)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer()
                if model.updatingSubscriptions.contains(subscription.id) {
                    ProgressView()
                }
                TestButton(group: subscription.id)
                Menu {
                    Button {
                        Task { await model.updateSubscription(subscription.id) }
                    } label: {
                        Label("Обновить", systemImage: "arrow.clockwise")
                    }
                    Button {
                        newName = subscription.name
                        renaming = true
                    } label: {
                        Label("Переименовать", systemImage: "pencil")
                    }
                    Button {
                        UIPasteboard.general.string = subscription.url
                        model.show("Ссылка подписки скопирована", error: false)
                    } label: {
                        Label("Скопировать ссылку", systemImage: "doc.on.doc")
                    }
                    Button {
                        onShowQR(QRItem(title: subscription.name, text: subscription.url))
                    } label: {
                        Label("QR-код подписки", systemImage: "qrcode")
                    }
                    if let support = subscription.supportURL.flatMap(URL.init(string:)) {
                        Button { openURL(support) } label: { Label("Поддержка", systemImage: "questionmark.bubble") }
                    }
                    if let page = subscription.webPageURL.flatMap(URL.init(string:)) {
                        Button { openURL(page) } label: { Label("Сайт провайдера", systemImage: "globe") }
                    }
                    Divider()
                    Button(role: .destructive) {
                        confirmDelete = true
                    } label: {
                        Label("Удалить подписку", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
            if let info = subscription.userInfo {
                UsageView(info: info)
            }
            if let announce = subscription.announce?.nonEmpty {
                Text(announce).font(.caption).foregroundStyle(.secondary)
            }
            if let error = subscription.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .textCase(nil)
        .buttonStyle(.borderless)
        .padding(.vertical, 4)
        .alert("Название подписки", isPresented: $renaming) {
            TextField("Название", text: $newName)
            Button("Сохранить") { model.renameSubscription(subscription.id, to: newName) }
            Button("Отмена", role: .cancel) {}
        }
        .confirmationDialog("Удалить «\(subscription.name)»?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Удалить", role: .destructive) { model.deleteSubscription(subscription.id) }
        }
    }
}
