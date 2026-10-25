import SwiftUI
import BKModel

/// 「我的」：系统设置风格的分组列表，二级页面用导航推入。
struct ProfileView: View {
    @Environment(LedgerStore.self) private var store
    @Environment(ExchangeRateStore.self) private var rates
    @AppStorage("appearance") private var appearance = AppearanceMode.system.rawValue
    @AppStorage(ExchangeRateStore.primaryKey) private var primaryCurrency = CurrencyCode.cny.rawValue
    @AppStorage(ExchangeRateStore.enabledKey) private var ratesEnabled = false
    @State private var retention = 30

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
                        VStack(alignment: .leading, spacing: 2) {
                            Text("本地账本").font(.title3.weight(.semibold))
                            Text("数据只保存在本机").font(.subheadline).foregroundStyle(.secondary)
                        }
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
                    Picker(selection: $primaryCurrency) {
                        ForEach(CurrencyCode.common, id: \.self) { code in
                            Text("\(code.chineseName) \(code.rawValue)").tag(code.rawValue)
                        }
                    } label: {
                        Label("主要币种", systemImage: "dollarsign.circle")
                    }
                    Toggle(isOn: $ratesEnabled) {
                        Label("联网获取汇率", systemImage: "arrow.left.arrow.right.circle")
                    }
                    if ratesEnabled {
                        LabeledContent("汇率", value: rateStatus)
                        Button("立即更新") { Task { await rates.refreshIfNeeded(force: true) } }
                            .disabled(rates.isUpdating)
                    }
                } header: {
                    Text("币种与汇率")
                } footer: {
                    Text(ratesEnabled
                         ? "资产页的净资产按主要币种换算合计。汇率约每 6 小时从 open.er-api.com 下载一次（数据每日更新），只发送币种代码，不上传任何账本数据。卡片和流水始终按原币种显示。"
                         : "资产页先显示主要币种的净资产，其他币种分开列出。打开联网获取汇率后，可以按主要币种换算合计。")
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
            .navigationTitle("我的")
            .onChange(of: ratesEnabled) { _, enabled in
                if enabled { Task { await rates.refreshIfNeeded(force: true) } }
            }
            .task { retention = await store.retentionDays() }
            .onChange(of: retention) { _, days in Task { await store.setRetentionDays(days) } }
        }
    }
}

extension ProfileView {
    private var rateStatus: String {
        if rates.isUpdating { return "正在更新…" }
        if let error = rates.lastError, rates.rates == nil { return error }
        guard let current = rates.rates else { return "尚未获取" }
        let updated = "更新于 \(Fmt.dateTime(current.updatedAt))"
        return rates.lastError == nil ? updated : "\(updated)（最近一次更新失败）"
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
                if store.accounts.isEmpty { Text("还没有添加银行卡").foregroundStyle(.secondary) }
                ForEach(store.accounts) { account in
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
