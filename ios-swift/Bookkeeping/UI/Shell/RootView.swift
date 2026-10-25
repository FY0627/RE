import SwiftUI
import Observation

enum AppTab: Hashable {
    case home
    case assets
    case stats
    case profile

    var title: String {
        switch self {
        case .home: "首页"
        case .assets: "资产"
        case .stats: "统计"
        case .profile: "我的"
        }
    }
    var symbol: String {
        switch self {
        case .home: "house"
        case .assets: "wallet.bifold"
        case .stats: "chart.bar"
        case .profile: "person"
        }
    }
}

/// 资产页当前展开的卡片；详情展开时隐藏标签栏。
@MainActor
@Observable
final class DetailMotionState {
    var selectedAccountID: String?

    var isOpen: Bool { selectedAccountID != nil }
}

enum ActiveSheet: Identifiable {
    case addAccount
    case pending

    var id: Int {
        switch self {
        case .addAccount: 0
        case .pending: 1
        }
    }
}

/// 系统原生 `TabView`：iOS 26 起标签栏自动使用液态玻璃，尺寸、字号、动效和无障碍都由系统提供。
/// 添加银行卡的「+」在资产页右上角。
struct RootView: View {
    @Environment(LedgerStore.self) private var store
    @State private var tab: AppTab = .home
    @State private var detail = DetailMotionState()
    @State private var sheet: ActiveSheet?

    var body: some View {
        TabView(selection: $tab) {
            Tab(AppTab.home.title, systemImage: AppTab.home.symbol, value: AppTab.home) {
                HomeView(openPending: { sheet = .pending })
            }
            Tab(AppTab.assets.title, systemImage: AppTab.assets.symbol, value: AppTab.assets) {
                AssetsView(openAddAccount: { sheet = .addAccount })
                    .toolbarVisibility(detail.isOpen ? .hidden : .visible, for: .tabBar)
            }
            Tab(AppTab.stats.title, systemImage: AppTab.stats.symbol, value: AppTab.stats) {
                StatsView()
            }
            Tab(AppTab.profile.title, systemImage: AppTab.profile.symbol, value: AppTab.profile) {
                ProfileView()
            }
        }
        .tabBarMinimizeBehavior(.never)
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .addAccount:
                AddAccountView()
            case .pending:
                PendingView()
            }
        }
        .environment(detail)
        .overlay(alignment: .topTrailing) {
            if PerfFlags.shared.showMetrics {
                MetricsOverlay().padding(.trailing, 8)
            }
        }
        .overlay {
            if case .failed(let message) = store.state {
                StorageErrorView(message: message) { Task { await store.retryStart() } }
            }
        }
    }
}

struct StorageErrorView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("无法打开本地账本", systemImage: "lock.shield")
        } description: {
            Text(message)
        } actions: {
            Button("重试", action: retry)
                .buttonStyle(.glassProminent)
                .controlSize(.large)
        }
        .background(Color(.systemBackground))
    }
}
