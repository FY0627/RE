import SwiftUI
import UIKit
import BKModel
import BKBackend

/// 「我的」：系统设置风格的分组列表，二级页面用导航推入。
struct ProfileView: View {
    @Environment(LedgerStore.self) private var store
    @Environment(ExchangeRateStore.self) private var rates
    @AppStorage("appearance") private var appearance = AppearanceMode.system.rawValue
    @AppStorage(ExchangeRateStore.primaryKey) private var primaryCurrency = CurrencyCode.cny.rawValue
    @AppStorage(IngestNotifier.modeKey) private var notifyMode = IngestNotifier.Mode.off.rawValue
    @State private var retention = 30
    @State private var notifyDenied = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        Image(systemName: "book.closed.fill")
                            .font(.title2)
                            .foregroundStyle(.white)
                            .frame(width: 56, height: 56)
                            .background(Color.accentColor.gradient, in: Circle())
                        Text("本地账本").font(.title3.weight(.semibold))
                    }
                    .padding(.vertical, 4)
                }

                Section("外观") {
                    Picker("外观", selection: $appearance) {
                        ForEach(AppearanceMode.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }

                Section {
                    NavigationLink {
                        CurrencyPicker(title: "主要币种", selection: primaryCurrencyList, multiple: false)
                    } label: {
                        LabeledContent {
                            Text(CurrencyCode(primaryCurrency).chineseName)
                        } label: {
                            Label("主要币种", systemImage: "dollarsign.circle")
                        }
                    }
                    LabeledContent("汇率", value: rateStatus)
                    NavigationLink {
                        ExchangeRateGuideView()
                    } label: {
                        Label("用快捷指令更新汇率", systemImage: "arrow.triangle.2.circlepath")
                    }
                    if rates.rates != nil {
                        Link(ExchangeRateFeed.attribution, destination: ExchangeRateFeed.attributionURL)
                    }
                } header: {
                    Text("币种与汇率")
                }

                Section("记账") {
                    NavigationLink {
                        CategoryManagerView()
                    } label: {
                        Label("分类", systemImage: "square.grid.2x2")
                    }
                }

                Section("自动记账") {
                    NavigationLink {
                        AutoSetupGuideView()
                    } label: {
                        Label("设置自动记账", systemImage: "bolt.badge.automatic")
                    }
                    NavigationLink {
                        AutomationStatusView()
                    } label: {
                        Label("自动记账状态", systemImage: "checkmark.seal")
                    }
                    NavigationLink {
                        TemplateListView()
                    } label: {
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
                    NavigationLink {
                        HelpView()
                    } label: {
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
                    NavigationLink {
                        PerformanceSettingsView()
                    } label: {
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
            .navigationTitle("我的")
            .task { retention = await store.retentionDays() }
            .onChange(of: retention) { _, days in Task { await store.setRetentionDays(days) } }
        }
    }
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

    var body: some View {
        List {
            Section("各卡最近一次成功接收") {
                if !store.accounts.contains(where: \.isCard) { Text("还没有添加银行卡").foregroundStyle(.secondary) }
                ForEach(store.accounts.filter(\.isCard)) { account in
                    let status = store.automation[account.id]
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(account.bankName) ·\(account.last4)")
                        if let last = status?.lastSuccessAt {
                            Text("已通过真实触发验证 · \(Fmt.dateTime(last))（\(status?.lastSuccessSource?.displayName ?? "")）· 累计 \(status?.receivedCount ?? 0) 次")
                                .font(.subheadline).foregroundStyle(.secondary)
                        } else {
                            Text("待验证 · 尚未收到这张卡的自动输入").font(.subheadline).foregroundStyle(.orange)
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
