import SwiftUI

@main
@MainActor
struct StrelaApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .task { await model.bootstrap() }
                .onOpenURL { url in
                    Task { await model.handleOpenURL(url) }
                }
                .onChange(of: scenePhase) { _, phase in
                    model.isForeground = phase == .active
                    if phase == .active {
                        Task { await model.didBecomeActive() }
                    } else if phase == .background {
                        BackgroundRefresh.schedule(afterHours: Double(model.state.settings.autoUpdateHours))
                    }
                }
        }
        .backgroundTask(.appRefresh(BackgroundRefresh.identifier)) { [model] in
            await model.backgroundRefresh()
        }
    }
}

enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
    case home, servers, routing, settings, logs

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Подключение"
        case .servers: return "Серверы"
        case .routing: return "Маршрутизация"
        case .settings: return "Настройки"
        case .logs: return "Журнал"
        }
    }

    var icon: String {
        switch self {
        case .home: return "power.circle"
        case .servers: return "server.rack"
        case .routing: return "arrow.triangle.branch"
        case .settings: return "gearshape"
        case .logs: return "doc.text.magnifyingglass"
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: SidebarItem? = .home
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(selection: $selection) {
                ForEach(SidebarItem.allCases) { item in
                    NavigationLink(value: item) {
                        Label(item.title, systemImage: item.icon)
                    }
                }
                Section {
                    SidebarStatus()
                }
            }
            .navigationTitle("Strela")
        } detail: {
            NavigationStack {
                switch selection ?? .home {
                case .home: HomeView()
                case .servers: ServersView()
                case .routing: RoutingView()
                case .settings: SettingsView()
                case .logs: LogsView()
                }
            }
        }
        .overlay(alignment: .top) {
            if let banner = model.banner {
                BannerView(banner: banner)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .onTapGesture { model.banner = nil }
            }
        }
        .animation(.spring(duration: 0.3), value: model.banner)
    }
}

/// Compact status in the sidebar: connection state and a quick toggle.
struct SidebarStatus: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack {
            Circle()
                .fill(model.vpn.isConnected ? Color.green : (model.vpn.isBusy || model.isConnecting ? Color.orange : Color.secondary))
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(StatusText.title(model.vpn.status, preparing: model.isConnecting)).font(.subheadline)
                Text(model.selectionTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { model.vpn.isActive },
                set: { _ in Task { await model.toggleConnection() } }
            ))
            .labelsHidden()
        }
    }
}
