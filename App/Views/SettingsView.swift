import SwiftUI
import UIKit

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmReset = false

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Picker("Тип проверки", selection: $model.state.settings.pingType) {
                    ForEach(PingType.allCases) { Text($0.title).tag($0) }
                }
                TextField("URL проверки", text: $model.state.settings.testURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Stepper("Таймаут: \(model.state.settings.pingTimeout) с", value: $model.state.settings.pingTimeout, in: 2...30)
                Stepper("Параллельно: \(model.state.settings.pingConcurrency)", value: $model.state.settings.pingConcurrency, in: 1...32)
                Toggle("Проверять при запуске", isOn: $model.state.settings.pingOnOpen)
            } header: {
                Text("Проверка задержки")
            } footer: {
                Text("Proxy GET — полноценный GET-запрос через сервер (как в Happ). При подключённом VPN проверка идёт из туннеля, без искажений.")
            }

            Section {
                Stepper("Кандидатов: \(model.state.settings.autoTopK)", value: $model.state.settings.autoTopK, in: 1...20)
                Stepper("Перепроверка: каждые \(model.state.settings.autoProbeMinutes) мин", value: $model.state.settings.autoProbeMinutes, in: 1...30)
            } header: {
                Text("Автовыбор")
            } footer: {
                Text("Перед подключением все серверы проверяются GET-запросом, лучшие попадают в балансировщик Xray (leastPing + observatory). Он сам переключается на самый быстрый и уходит с упавшего.")
            }

            Section {
                Toggle("Подключаться при запуске", isOn: $model.state.settings.autoConnectOnLaunch)
                Toggle("VPN по требованию (всегда включён)", isOn: $model.state.settings.onDemand)
                Toggle("Локальная сеть напрямую", isOn: $model.state.settings.excludeLocalNetworks)
                Toggle("Весь трафик в туннель (kill switch)", isOn: $model.state.settings.includeAllNetworks)
                Toggle("Push-уведомления Apple мимо VPN", isOn: $model.state.settings.excludeAPNs)
                Toggle("IPv6", isOn: $model.state.settings.enableIPv6)
                HStack {
                    Text("MTU")
                    Spacer()
                    TextField("1500", value: $model.state.settings.mtu, format: .number)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 100)
                }
            } header: {
                Text("Подключение")
            } footer: {
                Text("Изменения применяются при следующем подключении.")
            }

            Section {
                Toggle("Sniffing (домены для маршрутизации)", isOn: $model.state.settings.sniffing)
                Toggle("Mux", isOn: $model.state.settings.mux)
                Toggle("Фрагментация TLS", isOn: $model.state.settings.fragment.enabled)
                if model.state.settings.fragment.enabled {
                    LabeledTextField(title: "Пакеты", text: $model.state.settings.fragment.packets, placeholder: "tlshello")
                    LabeledTextField(title: "Длина", text: $model.state.settings.fragment.length, placeholder: "100-200")
                    LabeledTextField(title: "Интервал, мс", text: $model.state.settings.fragment.interval, placeholder: "10-20")
                }
                Picker("Уровень журнала", selection: $model.state.settings.logLevel) {
                    ForEach(["debug", "info", "warning", "error", "none"], id: \.self) { Text($0).tag($0) }
                }
            } header: {
                Text("Xray")
            } footer: {
                Text("Фрагментация разбивает TLS ClientHello к серверу — помогает, когда DPI режет соединение. Mux не применяется к XTLS Vision и XHTTP.")
            }

            Section {
                LabeledTextField(title: "User-Agent", text: $model.state.settings.userAgent, placeholder: "Strela/1.0")
                Toggle("Отправлять HWID", isOn: $model.state.settings.sendHWID)
                if model.state.settings.sendHWID {
                    LabeledContent("HWID", value: DeviceInfo.hwid)
                        .textSelection(.enabled)
                }
                Toggle("Шифрование подписок (age)", isOn: $model.state.settings.ageEncryption)
                Toggle("Обновлять подписки при запуске", isOn: $model.state.settings.updateSubscriptionsOnOpen)
                Stepper("Автообновление: каждые \(model.state.settings.autoUpdateHours) ч",
                        value: $model.state.settings.autoUpdateHours, in: 1...72)
            } header: {
                Text("Подписки")
            } footer: {
                Text("Подписки обновляются при запуске, по интервалу провайдера (profile-update-interval) или по этому значению, в том числе в фоне, если включено «Обновление контента» для приложения. HWID и модель устройства передаются в заголовках x-hwid, x-device-os, x-ver-os, x-device-model, как в Happ.")
            }

            Section {
                if let profile = ProvisioningProfile.embedded {
                    LabeledContent("Сертификат", value: profile.teamName ?? profile.teamID ?? "—")
                    LabeledContent("VPN (Network Extension)", value: profile.hasNetworkExtension ? "есть ✓" : "нет ✕")
                    LabeledContent("App Groups", value: profile.appGroups.isEmpty ? "нет" : "\(profile.appGroups.count)")
                    if let expiration = profile.expiration {
                        LabeledContent("Подпись до", value: Format.date(expiration))
                    }
                } else {
                    LabeledContent("Профиль подписи", value: "нет (TrollStore / без подписи)")
                }
                LabeledContent("App Group", value: AppGroup.isAvailable ? AppGroup.identifier : "недоступна")
            } header: {
                Text("Подпись")
            } footer: {
                Text("Для VPN нужен сертификат с Network Extension. Без App Groups VPN тоже работает: конфигурация передаётся в туннель напрямую, но гео-базы будут недоступны туннелю, и правила geoip/geosite отключатся.")
            }

            Section("О приложении") {
                LabeledContent("Версия", value: DeviceInfo.appVersion)
                LabeledContent("Ядро Xray", value: model.coreVersion)
                Button("Сбросить все данные", role: .destructive) { confirmReset = true }
            }
        }
        .navigationTitle("Настройки")
        .onChange(of: model.state.settings) {
            model.scheduleSave()
        }
        .confirmationDialog("Удалить подписки, серверы и профили?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Сбросить", role: .destructive) {
                Task { await model.resetAll() }
            }
        }
    }
}

struct LabeledTextField: View {
    let title: String
    @Binding var text: String
    let placeholder: String

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            TextField(placeholder, text: $text)
                .multilineTextAlignment(.trailing)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .foregroundStyle(.secondary)
        }
    }
}

struct LogsView: View {
    @Environment(AppModel.self) private var model
    @State private var source = 0
    @State private var text = ""

    private var url: URL { source == 0 ? Store.xrayLogURL : Store.appLogURL }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Журнал", selection: $source) {
                Text("Xray").tag(0)
                Text("Приложение").tag(1)
            }
            .pickerStyle(.segmented)
            .padding()
            ScrollView {
                Text(text.isEmpty ? "Журнал пуст" : text)
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.bottom)
            }
            .defaultScrollAnchor(.bottom)
        }
        .navigationTitle("Журнал")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    load()
                } label: {
                    Label("Обновить", systemImage: "arrow.clockwise")
                }
                if FileManager.default.fileExists(atPath: url.path) {
                    ShareLink(item: url) {
                        Label("Поделиться", systemImage: "square.and.arrow.up")
                    }
                }
                Button(role: .destructive) {
                    try? Data().write(to: url)
                    load()
                } label: {
                    Label("Очистить", systemImage: "trash")
                }
            }
        }
        .task(id: source) { load() }
    }

    private func load() {
        let local = Store.tail(of: url)
        text = local
        // Without a shared App Group the tunnel's logs live in its own container: ask it directly.
        guard model.vpn.isConnected, !AppGroup.isAvailable || local.isEmpty else { return }
        let wantXray = source == 0
        Task {
            if let logs = try? await model.vpn.tunnelLogs() {
                let remote = wantXray ? logs.xray : logs.app
                if !remote.isEmpty { text = remote }
            }
        }
    }
}
