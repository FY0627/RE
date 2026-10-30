import SwiftUI
import UIKit
import BKModel
import BKBackend

/// 「我的」：系统设置风格的分组列表，二级页面用导航推入（`ProfileRoute`）。推进去时标签栏滑出、回来时滑入，
/// 和资产页打开卡片详情一样：显隐放在整个导航栈上，在动画里切换。
/// 顶部一行和首页、资产页一样高、一样的位置；列表滚到它下面时垫一层磨砂背景（和首页一样）。
struct ProfileView: View {
    @Environment(LedgerStore.self) private var store
    @Environment(ExchangeRateStore.self) private var rates
    @AppStorage("appearance") private var appearance = AppearanceMode.system.rawValue
    @AppStorage(AppearanceMode.iconKey) private var appIcon = AppearanceMode.system.rawValue
    @AppStorage(ExchangeRateStore.primaryKey) private var primaryCurrency = CurrencyCode.cny.rawValue
    @AppStorage(IngestNotifier.modeKey) private var notifyMode = IngestNotifier.Mode.off.rawValue
    @State private var retention = 30
    @State private var notifyDenied = false
    @State private var scrolledUnderBar = false
    @State private var path: [ProfileRoute] = []
    /// 推进了二级页面：标签栏藏起来。和 `path` 分开、在动画里改，标签栏才会滑出 / 滑入，不是一下子没了
    @State private var subpageOpen = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack(path: $path) {
            Form {
                Section {
                    Picker(selection: $appearance) {
                        ForEach(AppearanceMode.allCases) { Text($0.title).tag($0.rawValue) }
                    } label: {
                        Label("外观", systemImage: "circle.lefthalf.filled")
                    }
                    Picker(selection: $appIcon) {
                        ForEach(AppearanceMode.allCases) { Text($0.title).tag($0.rawValue) }
                    } label: {
                        Label("图标", systemImage: "app")
                    }
                    .onChange(of: appIcon) { AppearanceMode.applyIcon() }
                } header: {
                    Text("显示")
                }

                Section {
                    NavigationLink(value: ProfileRoute.primaryCurrency) {
                        LabeledContent {
                            Text(CurrencyCode(primaryCurrency).chineseName)
                        } label: {
                            Label("主要币种", systemImage: "dollarsign.circle")
                        }
                    }
                    NavigationLink(value: ProfileRoute.exchangeRates) {
                        Label("用快捷指令更新汇率", systemImage: "arrow.triangle.2.circlepath")
                    }
                    LabeledContent("汇率", value: rateStatus)
                    if rates.rates != nil {
                        Link(ExchangeRateFeed.attribution, destination: ExchangeRateFeed.attributionURL)
                    }
                } header: {
                    Text("币种与汇率")
                }

                Section("记账") {
                    NavigationLink(value: ProfileRoute.categories) {
                        Label("分类", systemImage: "square.grid.2x2")
                    }
                }

                Section("自动记账") {
                    NavigationLink(value: ProfileRoute.autoSetup) {
                        Label("设置自动记账", systemImage: "bolt.badge.automatic")
                    }
                    NavigationLink(value: ProfileRoute.automationStatus) {
                        Label("自动记账状态", systemImage: "checkmark.seal")
                    }
                    NavigationLink(value: ProfileRoute.templates) {
                        Label("识别模板", systemImage: "text.viewfinder")
                    }
                    Picker(selection: $notifyMode) {
                        ForEach(IngestNotifier.Mode.allCases) { Text($0.title).tag($0.rawValue) }
                    } label: {
                        Label("记账结果通知", systemImage: "bell.badge")
                    }
                    .onChange(of: notifyMode) { _, mode in
                        guard mode != IngestNotifier.Mode.off.rawValue else { return }
                        Task {
                            if !(await IngestNotifier.requestAuthorization()) {
                                notifyMode = IngestNotifier.Mode.off.rawValue
                                notifyDenied = true
                            }
                        }
                    }
                    NavigationLink(value: ProfileRoute.help) {
                        Label("使用说明", systemImage: "questionmark.circle")
                    }
                }

                Section {
                    Picker(selection: $retention) {
                        Text("7 天").tag(7)
                        Text("30 天").tag(30)
                        Text("90 天").tag(90)
                    } label: {
                        Label("原始通知保留", systemImage: "clock.arrow.circlepath")
                    }
                } header: {
                    Text("隐私与数据")
                }

                Section("开发与调试") {
                    NavigationLink(value: ProfileRoute.performance) {
                        Label("性能开关与调试指标", systemImage: "speedometer")
                    }
                }

                Section("关于") {
                    LabeledContent("日常记账", value: "iOS 原生 Swift 版")
                    LabeledContent("版本", value: BuildInfo.summary)
                        .font(.subheadline.monospaced())
                }
            }
            .alert("没有通知权限", isPresented: $notifyDenied) {
                Button("去设置") {
                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("在系统设置里允许日常记账发送通知。")
            }
            .trackingScrollUnderTopBar($scrolledUnderBar)
            .navigationTitle("我的")
            // 系统导航栏的大标题比资产页的标题行低；藏起来，自己放一行
            .navigationBarTitleDisplayMode(.inline)
            .toolbarVisibility(.hidden, for: .navigationBar)
            .safeAreaBar(edge: .top) {
                TitleBar(title: "我的")
                    .frame(height: GlassControls.size)
                    .padding(.horizontal, AppLayout.cardInset)
                    .padding(.top, 2)
                    .padding(.bottom, 6)
                    .background { TopBarBackdrop(visible: scrolledUnderBar) }
            }
            .navigationDestination(for: ProfileRoute.self) { destination($0) }
            .task { retention = await store.retentionDays() }
            .onChange(of: retention) { _, days in Task { await store.setRetentionDays(days) } }
        }
        .toolbarVisibility(subpageOpen ? .hidden : .visible, for: .tabBar)
        .onChange(of: path.isEmpty) { _, empty in
            withAnimation(.smooth(duration: 0.35)) { subpageOpen = !empty }
        }
    }

    @ViewBuilder
    private func destination(_ route: ProfileRoute) -> some View {
        switch route {
        case .primaryCurrency: CurrencyPicker(title: "主要币种", selection: primaryCurrencyList, multiple: false)
        case .exchangeRates: ExchangeRateGuideView()
        case .categories: CategoryManagerView()
        case .autoSetup: AutoSetupGuideView()
        case .automationStatus: AutomationStatusView()
        case .templates: TemplateListView()
        case .help: HelpView()
        case .performance: PerformanceSettingsView()
        }
    }
}

/// 「我的」推进去的二级页面
enum ProfileRoute: Hashable {
    case primaryCurrency, exchangeRates, categories, autoSetup, automationStatus, templates, help, performance
}

extension ProfileView {
    private var rateStatus: String {
        rates.rates.map { "更新于 \(Fmt.dateTime($0.updatedAt))" } ?? "尚未导入"
    }

    /// 选币种页面用的单选列表
    private var primaryCurrencyList: Binding<[CurrencyCode]> {
        Binding { [CurrencyCode(primaryCurrency)] } set: { codes in
            if let code = codes.first { primaryCurrency = code.rawValue }
        }
    }
}

enum BuildInfo {
    static var summary: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        let commit = (info["BKBuildCommit"] as? String).map { String($0.prefix(7)) } ?? "本地构建"
        return "\(version) (\(build)) · \(commit)"
    }
}

/// 自动记账的可观测状态。App 无法读取快捷指令里自动化是否存在或已启用，
/// 这里只展示 App 自己能确认的事实。
struct AutomationStatusView: View {
    @Environment(LedgerStore.self) private var store
    @State private var log: [IngestLogEntry] = []

    /// 能自动记账的账户：银行卡，和选了是哪个钱包的电子钱包
    private var automated: [Account] {
        store.accounts.filter { $0.isCard || WalletDirectory.provider(of: $0) != nil }
    }

    var body: some View {
        List {
            Section("各账户最近一次成功接收") {
                if automated.isEmpty { Text("还没有添加银行卡").foregroundStyle(.secondary) }
                ForEach(automated) { account in
                    let status = store.automation[account.id]
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.displayTitle)
                        if let last = status?.lastSuccessAt {
                            Text("已通过真实触发验证 · \(Fmt.dateTime(last))（\(status?.lastSuccessSource?.displayName ?? "")）· 累计 \(status?.receivedCount ?? 0) 次")
                                .font(.subheadline).foregroundStyle(.secondary)
                        } else {
                            Text("待验证 · 尚未收到这个账户的自动输入").font(.subheadline).foregroundStyle(.orange)
                        }
                    }
                }
            }
            Section {
                if log.isEmpty { Text("还没有收到任何输入").foregroundStyle(.secondary) }
                ForEach(log) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(entry.detail.isEmpty ? entry.classification.displayName : entry.detail)
                            Spacer()
                            Text(entry.source.displayName).font(.subheadline).foregroundStyle(.secondary)
                        }
                        Text("处理于 \(Fmt.dateTime(entry.processedAt))" + (entry.receivedAt.map { " · 接收于 \(Fmt.dateTime($0))" } ?? " · 系统未提供接收时间"))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("接收日志（最近 100 条）")
            }
        }
        .navigationTitle("自动记账状态")
        .navigationBarTitleDisplayMode(.inline)
        .task { log = await store.ingestLog() }
        .refreshable { await store.refresh(); log = await store.ingestLog() }
    }
}

struct PerformanceSettingsView: View {
    @Bindable private var flags = PerfFlags.shared

    var body: some View {
        Form {
            Section {
                Toggle("卡片阴影", isOn: $flags.cardShadows)
                Toggle("卡面合成为位图（drawingGroup）", isOn: $flags.rasterizeCards)
            } header: {
                Text("单变量开关")
            }
            Section {
                Toggle("显示帧率与内存", isOn: $flags.showMetrics)
            }
            Section {
                Button("恢复默认") { flags.resetToDefaults() }
            }
        }
        .navigationTitle("性能开关")
        .navigationBarTitleDisplayMode(.inline)
    }
}
