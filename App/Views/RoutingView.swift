import SwiftUI
import UIKit

struct RoutingView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: EditTarget?

    struct EditTarget: Identifiable {
        let id = UUID()
        let profile: RoutingProfile
        let originalName: String?
    }

    var body: some View {
        List {
            Section {
                Toggle("Умная маршрутизация", isOn: Binding(
                    get: { model.state.routingEnabled },
                    set: { value in
                        model.state.routingEnabled = value
                        Task { await model.routingToggled() }
                    }
                ))
            } footer: {
                Text("Выключено — весь трафик идёт через VPN (кроме локальной сети). Профили совместимы с Happ: ссылки happ://routing/add/… и routing-заголовок подписки.")
            }

            Section("Профили") {
                ForEach(model.state.routingProfiles) { profile in
                    Button {
                        Task { await model.activateRouting(profile.name) }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(profile.name).foregroundStyle(.primary)
                                Text(summary(profile)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Spacer()
                            if profile.name == model.state.activeRoutingName {
                                Image(systemName: "checkmark").foregroundStyle(.tint)
                            }
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        if !profile.isBuiltIn {
                            Button(role: .destructive) {
                                model.deleteRouting(profile.name)
                            } label: {
                                Label("Удалить", systemImage: "trash")
                            }
                        }
                        Button {
                            editing = EditTarget(profile: profile, originalName: profile.isBuiltIn ? nil : profile.name)
                        } label: {
                            Label("Изменить", systemImage: "pencil")
                        }
                        .tint(.blue)
                    }
                    .contextMenu {
                        Button {
                            editing = EditTarget(profile: profile, originalName: profile.isBuiltIn ? nil : profile.name)
                        } label: {
                            Label(profile.isBuiltIn ? "Изменить копию" : "Изменить", systemImage: "pencil")
                        }
                        Button {
                            UIPasteboard.general.string = HappRouting.exportLink(profile)
                            model.show("Ссылка профиля скопирована", error: false)
                        } label: {
                            Label("Скопировать ссылку (happ://routing)", systemImage: "link")
                        }
                        if !profile.isBuiltIn {
                            Button(role: .destructive) {
                                model.deleteRouting(profile.name)
                            } label: {
                                Label("Удалить", systemImage: "trash")
                            }
                        }
                    }
                }
                PasteButton(payloadType: String.self) { strings in
                    guard let text = strings.first else { return }
                    Task { @MainActor in await model.importRoutingLink(text) }
                }
                Button {
                    var profile = RoutingPresets.smart
                    profile.name = "Мой профиль"
                    profile.isBuiltIn = false
                    editing = EditTarget(profile: profile, originalName: nil)
                } label: {
                    Label("Новый профиль", systemImage: "plus")
                }
            }

            Section {
                LabeledContent("geoip.dat", value: GeoFiles.describe(GeoFiles.geoipURL))
                LabeledContent("geosite.dat", value: GeoFiles.describe(GeoFiles.geositeURL))
                Button {
                    Task { await model.ensureGeoFiles(force: true) }
                } label: {
                    if model.geoBusy {
                        ProgressView()
                    } else {
                        Label("Обновить гео-файлы", systemImage: "arrow.down.circle")
                    }
                }
                .disabled(model.geoBusy)
            } header: {
                Text("Гео-файлы")
            } footer: {
                Text("Базы geoip/geosite скачиваются по ссылкам активного профиля (по умолчанию runetfreedom/russia-v2ray-rules-dat) и обновляются раз в неделю.")
            }
        }
        .navigationTitle("Маршрутизация")
        .sheet(item: $editing) { target in
            RoutingEditor(profile: target.profile, originalName: target.originalName)
        }
    }

    private func summary(_ profile: RoutingProfile) -> String {
        var parts: [String] = [profile.globalProxy ? "по умолчанию VPN" : "по умолчанию напрямую"]
        let direct = profile.directSites.count + profile.directIP.count
        let proxy = profile.proxySites.count + profile.proxyIP.count
        let block = profile.blockSites.count + profile.blockIP.count
        if direct > 0 { parts.append("напрямую: \(direct)") }
        if proxy > 0 { parts.append("через VPN: \(proxy)") }
        if block > 0 { parts.append("блок: \(block)") }
        return parts.joined(separator: " · ")
    }
}

struct RoutingEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let originalName: String?
    @State private var profile: RoutingProfile
    @State private var directSites: String
    @State private var directIP: String
    @State private var proxySites: String
    @State private var proxyIP: String
    @State private var blockSites: String
    @State private var blockIP: String
    @State private var hosts: String

    init(profile: RoutingProfile, originalName: String?) {
        self.originalName = originalName
        _profile = State(initialValue: profile)
        _directSites = State(initialValue: profile.directSites.joined(separator: "\n"))
        _directIP = State(initialValue: profile.directIP.joined(separator: "\n"))
        _proxySites = State(initialValue: profile.proxySites.joined(separator: "\n"))
        _proxyIP = State(initialValue: profile.proxyIP.joined(separator: "\n"))
        _blockSites = State(initialValue: profile.blockSites.joined(separator: "\n"))
        _blockIP = State(initialValue: profile.blockIP.joined(separator: "\n"))
        _hosts = State(initialValue: profile.dnsHosts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: "\n"))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Основное") {
                    TextField("Название", text: $profile.name)
                    Toggle("По умолчанию через VPN", isOn: $profile.globalProxy)
                    Picker("Domain strategy", selection: $profile.domainStrategy) {
                        ForEach(["AsIs", "IPIfNonMatch", "IPOnDemand"], id: \.self) { Text($0).tag($0) }
                    }
                }
                listSection("Через VPN: домены", text: $proxySites, hint: "geosite:youtube, domain:example.com, full:api.example.com")
                listSection("Через VPN: IP", text: $proxyIP, hint: "geoip:telegram, 1.2.3.0/24")
                listSection("Напрямую: домены", text: $directSites, hint: "geosite:category-ru, domain:ru")
                listSection("Напрямую: IP", text: $directIP, hint: "geoip:ru, 10.0.0.0/8")
                listSection("Блокировать: домены", text: $blockSites, hint: "geosite:category-ads-all")
                listSection("Блокировать: IP", text: $blockIP, hint: "")
                Section("DNS через VPN (удалённый)") {
                    dnsTypePicker($profile.remoteDNSType)
                    TextField("DoH URL", text: $profile.remoteDNSDomain).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("IP", text: $profile.remoteDNSIP).keyboardType(.numbersAndPunctuation)
                }
                Section("DNS напрямую (внутренний)") {
                    dnsTypePicker($profile.domesticDNSType)
                    TextField("DoH URL", text: $profile.domesticDNSDomain).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("IP", text: $profile.domesticDNSIP).keyboardType(.numbersAndPunctuation)
                }
                listSection("DNS hosts (домен IP)", text: $hosts, hint: "cloudflare-dns.com 1.1.1.1")
                Section("Гео-файлы") {
                    TextField("geoip.dat", text: $profile.geoipURL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("geosite.dat", text: $profile.geositeURL).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
            }
            .navigationTitle(originalName == nil ? "Новый профиль" : "Профиль")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") { save() }.disabled(profile.name.trimmed.isEmpty)
                }
            }
        }
    }

    private func listSection(_ title: String, text: Binding<String>, hint: String) -> some View {
        Section {
            TextEditor(text: text)
                .font(.system(.footnote, design: .monospaced))
                .frame(minHeight: 72)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        } header: {
            Text(title)
        } footer: {
            if !hint.isEmpty { Text("По одному на строку, например: \(hint)") }
        }
    }

    private func dnsTypePicker(_ selection: Binding<String>) -> some View {
        Picker("Тип", selection: selection) {
            Text("DoH").tag("DoH")
            Text("DoU (UDP)").tag("DoU")
        }
        .pickerStyle(.segmented)
    }

    private func lines(_ text: String) -> [String] {
        text.components(separatedBy: CharacterSet(charactersIn: "\n,")).compactMap { $0.trimmed.nonEmpty }
    }

    private func save() {
        var updated = profile
        updated.name = profile.name.trimmed
        updated.directSites = lines(directSites)
        updated.directIP = lines(directIP)
        updated.proxySites = lines(proxySites)
        updated.proxyIP = lines(proxyIP)
        updated.blockSites = lines(blockSites)
        updated.blockIP = lines(blockIP)
        var dnsHosts: [String: String] = [:]
        for line in hosts.components(separatedBy: .newlines) {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "=" || $0 == "\t" }).map(String.init)
            if parts.count >= 2 { dnsHosts[parts[0]] = parts[1] }
        }
        updated.dnsHosts = dnsHosts
        Task {
            await model.saveRouting(updated, replacing: originalName)
            dismiss()
        }
    }
}
