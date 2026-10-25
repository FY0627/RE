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

    /// 打开 / 关闭详情的动画；资产页的卡片、返回按钮和标签栏都用它，节奏一致
    static func transition(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.25) : .spring(response: 0.5, dampingFraction: 0.86)
    }
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var tab: AppTab = .home
    @State private var detail = DetailMotionState()
    @State private var sheet: ActiveSheet?
    /// 离开「我的」时 +1，让它下次进入时重建：滚动位置回到最上方，二级页面也关闭
    @State private var profileVisit = 0
    /// 找不到系统标签栏、无法做淡出缩放时，退回系统的隐藏方式
    @State private var systemTabBarHide = false

    var body: some View {
        TabView(selection: $tab) {
            Tab(AppTab.home.title, systemImage: AppTab.home.symbol, value: AppTab.home) {
                HomeView(openPending: { sheet = .pending })
            }
            Tab(AppTab.assets.title, systemImage: AppTab.assets.symbol, value: AppTab.assets) {
                AssetsView(openAddAccount: { sheet = .addAccount })
                    .toolbarVisibility(systemTabBarHide && detail.isOpen ? .hidden : .visible, for: .tabBar)
            }
            Tab(AppTab.stats.title, systemImage: AppTab.stats.symbol, value: AppTab.stats) {
                StatsView()
            }
            Tab(AppTab.profile.title, systemImage: AppTab.profile.symbol, value: AppTab.profile) {
                ProfileView()
                    .id(profileVisit)
            }
        }
        .tabBarMinimizeBehavior(.never)
        .onChange(of: tab) { old, _ in
            if old == .profile { profileVisit += 1 }
        }
        .onChange(of: detail.isOpen) { _, open in
            // 标签栏和返回按钮一样淡出并缩小
            if !TabBarFader.setVisible(!open, animation: DetailMotionState.transition(reduceMotion: reduceMotion)) {
                systemTabBarHide = true
            }
        }
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
