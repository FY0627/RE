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
/// 上拉手势（`PullAddButton`）盖在这个系统按钮上；找不到按钮位置时退回系统按钮的轻点打开。
struct RootView: View {
    @Environment(LedgerStore.self) private var store
    @State private var tab: AppTab = .home
    @State private var detail = DetailMotionState()
    @State private var sheet: ActiveSheet?
    @State private var addFrame: CGRect?
    @State private var addInteracting = false

    static let addTitle = "添加"

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
            // 必须用标准的「标题 + 图标 + value + role」写法：自定义 label 的写法会让系统不再把它单独画成圆形按钮。
            // 上拉层接管「+」的绘制后换成透明图标（同样是标准写法），系统按钮只保留玻璃底，拉动时不会出现两个「+」。
            if addFrame == nil {
                Tab(Self.addTitle, systemImage: AppTab.add.symbol, value: AppTab.add, role: .search) {
                    Color.clear
                }
            }
            if addFrame != nil {
                Tab(Self.addTitle, image: "TabAddBlank", value: AppTab.add, role: .search) {
                    Color.clear
                }
            }
        }
        .tabBarMinimizeBehavior(.never)
        .overlay { pullLayer }
        .task(id: ProbeKey(detailOpen: detail.isOpen, tab: tab)) { await probeAddButton() }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .addAccount:
                AddAccountView()
            case .manualEntryUnavailable:
                ManualEntryUnavailableView()
                    .presentationDetents([.height(180)])
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

    /// 选中「+」时不切换页面：资产页打开添加银行卡，其他页面说明手动记账暂未开放。
    private var selection: Binding<AppTab> {
        Binding {
            tab
        } set: { newValue in
            guard newValue == .add else {
                tab = newValue
                return
            }
            triggerAdd()
        }
    }

    private func triggerAdd() {
        guard !detail.isOpen, sheet == nil else { return }
        sheet = tab == .assets ? .addAccount : .manualEntryUnavailable
    }

    /// 盖在系统「+」上的上拉层。只有按钮本身接收触摸，其余区域透明不拦截。
    private var pullLayer: some View {
        GeometryReader { proxy in
            if let frame = addFrame, !detail.isOpen {
                let origin = proxy.frame(in: .global).origin
                PullAddButton(
                    diameter: frame.width,
                    screenHeight: proxy.size.height,
                    sheetActive: sheet != nil,
                    isInteracting: $addInteracting,
                    onTrigger: triggerAdd
                )
                .position(x: frame.midX - origin.x, y: frame.midY - origin.y)
            }
        }
        .ignoresSafeArea()
    }

    private struct ProbeKey: Hashable {
        let detailOpen: Bool
        let tab: AppTab
    }

    /// 标签栏布局完成后读取系统「+」的位置；详情展开（标签栏隐藏）时不显示上拉层。
    private func probeAddButton() async {
        guard !detail.isOpen else { return }
        for attempt in 0..<10 {
            try? await Task.sleep(for: .milliseconds(attempt == 0 ? 350 : 500))
            if Task.isCancelled { return }
            if let frame = TabBarProbe.addButtonFrame(title: Self.addTitle, lastTabTitle: AppTab.profile.title) {
                if frame != addFrame { addFrame = frame }
                return
            }
        }
    }
}

struct ManualEntryUnavailableView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("手动记账将在以后的版本开放。")
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
