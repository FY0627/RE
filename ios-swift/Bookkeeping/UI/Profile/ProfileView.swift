import SwiftUI
import BKModel

/// 「我的」：系统设置风格的分组列表，二级页面用导航推入。
struct ProfileView: View {
    @Environment(LedgerStore.self) private var store
    @AppStorage("appearance") private var appearance = AppearanceMode.system.rawValue
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
                            Text("无需登录 · 数据只保存在这台 iPhone").font(.subheadline).foregroundStyle(.secondary)
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
                        Label("使用说明与限制", systemImage: "questionmark.circle")
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
                } footer: {
                    Text("短信 / 邮件原文只保存在本机，用于核对和处理待处理项；到期后自动清空正文，流水和去重指纹保留。验证码正文从不保存。")
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
            .task { retention = await store.retentionDays() }
            .onChange(of: retention) { _, days in Task { await store.setRetentionDays(days) } }
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
            Section {
                Label("已提供 App 动作「记录银行动账通知」", systemImage: "checkmark.circle.fill")
                Label("快捷指令里的自动化是否已创建、已启用：iOS 不向 App 提供查询接口，请在「快捷指令 › 自动化」中查看", systemImage: "questionmark.circle")
                    .font(.subheadline)
            } header: {
                Text("App 能确认的事实")
            }
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
            } footer: {
                Text("每次快捷指令把内容交给 App 都会在这里留下一条记录，包括被过滤、重复和空输入。日志只在本机。")
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
                Toggle("转场遮挡遮罩", isOn: $flags.flightMask)
            } header: {
                Text("单变量开关")
            } footer: {
                Text("一次只改一个开关，其余保持默认，在同一台 iPhone 上重复同一操作并录屏对照。标签栏、导航栏和按钮都是系统原生控件，液态玻璃由系统渲染。")
            }
            Section {
                Toggle("显示帧率与内存", isOn: $flags.showMetrics)
            } footer: {
                Text("读数是 App 内的粗略统计（CADisplayLink 帧间隔与内存占用），不能替代 Instruments；没有真机测量记录前，不宣称达到任何帧率或功耗目标。")
            }
            Section {
                Button("恢复默认") { flags.resetToDefaults() }
            }
        }
        .navigationTitle("性能开关")
        .navigationBarTitleDisplayMode(.inline)
    }
}
