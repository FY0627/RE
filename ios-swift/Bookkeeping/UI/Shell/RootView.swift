import SwiftUI
import Observation

enum AppTab: Int, CaseIterable, Identifiable, Hashable {
    case home
    case assets
    case stats
    case profile

    var id: Int { rawValue }
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

/// 横向翻页的连续位置。只有底部导航的指示块读取它，翻页时不会让整页重新计算。
@MainActor
@Observable
final class PagerState {
    var position: CGFloat = 0
}

/// 资产页卡片详情的转场状态，底部导航和加号据此收起。
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

struct RootView: View {
    @Environment(LedgerStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    @State private var tab: AppTab? = .home
    @State private var pager = PagerState()
    @State private var detail = DetailMotionState()
    @State private var sheet: ActiveSheet?
    @State private var addInteracting = false

    private var currentTab: AppTab { tab ?? .home }

    var body: some View {
        let palette = Theme(scheme: scheme)
        GeometryReader { proxy in
            ZStack(alignment: .bottom) {
                palette.bg.ignoresSafeArea()
                pages(size: proxy.size)
                    .allowsHitTesting(!addInteracting)
                bottomBar(screenHeight: proxy.size.height)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 6)
                if PerfFlags.shared.showMetrics {
                    MetricsOverlay()
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(.trailing, 8)
                }
            }
        }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .addAccount:
                AddAccountView()
            case .manualEntryUnavailable:
                ManualEntryUnavailableView()
                    .presentationDetents([.height(280)])
            case .pending:
                PendingView()
            }
        }
        .environment(detail)
        .overlay {
            if case .failed(let message) = store.state {
                StorageErrorView(message: message) { Task { await store.retryStart() } }
            }
        }
    }

    private func pages(size: CGSize) -> some View {
        ScrollView(.horizontal) {
            // 四个页面常驻（不是 Lazy），切页时保留各自的滚动位置和状态
            HStack(spacing: 0) {
                ForEach(AppTab.allCases) { page in
                    pageView(page)
                        .containerRelativeFrame(.horizontal)
                        .id(page)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $tab)
        .scrollIndicators(.hidden)
        .scrollDisabled(detail.isOpen || addInteracting)
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentOffset.x / max(1, geometry.containerSize.width)
        } action: { _, position in
            pager.position = position
        }
    }

    @ViewBuilder
    private func pageView(_ page: AppTab) -> some View {
        switch page {
        case .home: HomeView(openPending: { sheet = .pending })
        case .assets: AssetsView(openPending: { sheet = .pending }, openAddAccount: { sheet = .addAccount })
        case .stats: StatsView()
        case .profile: ProfileView()
        }
    }

    private func bottomBar(screenHeight: CGFloat) -> some View {
        HStack(spacing: 10) {
            LiquidDock(selected: currentTab, pager: pager) { selected in
                guard !detail.isOpen, !addInteracting else { return }
                withAnimation(.timingCurve(0.22, 0.7, 0.35, 1, duration: 0.56)) { tab = selected }
            }
            .modifier(CollapseTransition(progress: detail.progress, active: currentTab == .assets, circular: false))

            PullAddButton(
                screenHeight: screenHeight,
                label: currentTab == .assets ? "添加银行卡" : "记一笔（暂未开放）",
                sheetActive: sheet != nil,
                isInteracting: $addInteracting
            ) {
                sheet = currentTab == .assets ? .addAccount : .manualEntryUnavailable
            }
            .modifier(CollapseTransition(progress: detail.progress, active: currentTab == .assets, circular: true))
        }
        .allowsHitTesting(!(currentTab == .assets && detail.isOpen))
    }
}

/// 详情展开时底部控件居中收起（原型 `CenteredControlTransition` + `dockCollapse`）。
struct CollapseTransition: ViewModifier, Animatable {
    var progress: Double
    var active: Bool
    var circular: Bool

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let collapse = active ? DetailMotion.dockCollapse(progress) : 0
        let visible = 1 - collapse
        let scaleX = circular ? 0.12 + 0.88 * visible : 0.1 + 0.9 * visible
        let scaleY = circular ? scaleX : 0.75 + 0.25 * visible
        content
            .scaleEffect(x: scaleX, y: scaleY, anchor: .center)
            .opacity(visible)
    }
}

struct ManualEntryUnavailableView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = Theme(scheme: scheme)
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("手动记账暂未开放").font(.system(size: 18, weight: .bold)).foregroundStyle(palette.ink)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 14, weight: .semibold)).foregroundStyle(palette.ink)
                        .frame(width: 32, height: 32).background(palette.ink.opacity(0.06), in: Circle())
                }
                .accessibilityLabel("关闭")
            }
            Text("当前版本只记录银行卡通知带来的资金变动。手动记一笔会在以后的版本开放，这里不会创建任何账单。")
                .font(.system(size: 13)).foregroundStyle(palette.muted)
            Text("想记录某张卡的流水：到「资产」添加这张卡，再点卡片详情里的「设置自动记账」。")
                .font(.system(size: 13)).foregroundStyle(palette.muted)
            Spacer(minLength: 0)
        }
        .padding(20)
        .presentationCornerRadius(28)
    }
}

struct StorageErrorView: View {
    let message: String
    let retry: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = Theme(scheme: scheme)
        VStack(spacing: 12) {
            Image(systemName: "lock.shield").font(.system(size: 34)).foregroundStyle(palette.muted)
            Text(message).font(.system(size: 14)).multilineTextAlignment(.center).foregroundStyle(palette.ink)
            Button("重试", action: retry).buttonStyle(.borderedProminent)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.bg)
    }
}
