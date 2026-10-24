import SwiftUI
import Observation

enum AppTab: Hashable {
    case home
    case assets
    case stats
    case profile
    /// 标签栏右侧独立的圆形「+」按钮。点按时不切换页面，只打开对应面板。
    case add

    var title: String {
        switch self {
        case .home: "首页"
        case .assets: "资产"
        case .stats: "统计"
        case .profile: "我的"
        case .add: "添加"
        }
    }
    var symbol: String {
        switch self {
        case .home: "house"
        case .assets: "wallet.bifold"
        case .stats: "chart.bar"
        case .profile: "person"
        case .add: "plus"
        }
    }
}

/// 资产页卡片详情的转场状态；详情展开时隐藏标签栏。
@MainActor
@Observable
final class DetailMotionState {
    var selectedAccountID: String?
    var progress: Double = 0
    var isAnimating = false

    var isOpen: Bool { selectedAccountID != nil }
}

enum ActiveSheet: Identifiable {
    case addAccount
    case manualEntryUnavailable
    case pending

    var id: Int {
        switch self {
        case .addAccount: 0
        case .manualEntryUnavailable: 1
        case .pending: 2
        }
    }
}

/// 系统原生 `TabView`：iOS 26 起标签栏自动使用液态玻璃，尺寸、字号、动效和无障碍都由系统提供。
/// 「+」用 `role: .search` 的标签显示成标签栏右侧独立的圆形按钮（系统布局），点按时拦截选择，不切换页面。
struct RootView: View {
    @Environment(LedgerStore.self) private var store
    @State private var tab: AppTab = .home
    @State private var detail = DetailMotionState()
    @State private var sheet: ActiveSheet?

    var body: some View {
        TabView(selection: selection) {
            Tab(AppTab.home.title, systemImage: AppTab.home.symbol, value: AppTab.home) {
                HomeView(openPending: { sheet = .pending })
            }
            Tab(AppTab.assets.title, systemImage: AppTab.assets.symbol, value: AppTab.assets) {
                AssetsView(openPending: { sheet = .pending }, openAddAccount: { sheet = .addAccount })
                    .toolbarVisibility(detail.isOpen ? .hidden : .visible, for: .tabBar)
            }
            Tab(AppTab.stats.title, systemImage: AppTab.stats.symbol, value: AppTab.stats) {
                StatsView()
            }
            Tab(AppTab.profile.title, systemImage: AppTab.profile.symbol, value: AppTab.profile) {
                ProfileView()
            }
            Tab(tab == .assets ? "添加银行卡" : "记一笔", systemImage: AppTab.add.symbol, value: AppTab.add, role: .search) {
                Color.clear
            }
        }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .addAccount:
                AddAccountView()
            case .manualEntryUnavailable:
                ManualEntryUnavailableView()
                    .presentationDetents([.medium])
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
        .task(id: store.state) {
            // CI 截图：数据就绪后停到指定页面，等转场和材质渲染完成再通知脚本
            guard ScreenshotMode.isActive, store.state == .ready else { return }
            if let page = ScreenshotMode.tab { tab = page }
            if ScreenshotMode.opensPending { sheet = .pending }
            try? await Task.sleep(for: .milliseconds(1500))
            ScreenshotMode.markReady()
        }
        .overlay {
            if case .failed(let message) = store.state {
                StorageErrorView(message: message) { Task { await store.retryStart() } }
            }
        }
    }

    /// 选中「+」时不切换页面：资产页打开添加银行卡，其他页面说明手动记账暂未开放。
    private var selection: Binding<AppTab> {
        Binding {
            tab
        } set: { newValue in
            guard newValue == .add else {
                tab = newValue
                return
            }
            guard !detail.isOpen, sheet == nil else { return }
            sheet = tab == .assets ? .addAccount : .manualEntryUnavailable
        }
    }
}

struct ManualEntryUnavailableView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("当前版本只记录银行卡通知带来的资金变动。手动记一笔会在以后的版本开放，这里不会创建任何账单。")
                Text("想记录某张卡的流水：到「资产」添加这张卡，再按「设置自动记账」的步骤设置一次即可。")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .font(.body)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            .navigationTitle("手动记账暂未开放")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("好", systemImage: "checkmark") { dismiss() }
                }
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
