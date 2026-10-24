import SwiftUI
import BKModel

struct ProfileView: View {
    @Environment(LedgerStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    @AppStorage("appearance") private var appearance = AppearanceMode.system.rawValue
    @State private var showStatus = false
    @State private var showPerf = false
    @State private var showHelp = false
    @State private var retention = 30

    var body: some View {
        let palette = Theme(scheme: scheme)
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 14) {
                    Circle().fill(palette.surface).frame(width: 52, height: 52)
                        .overlay(Text("记").font(.system(size: 20, weight: .semibold)).foregroundStyle(palette.ink))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("本地账本").font(.system(size: 18, weight: .bold)).foregroundStyle(palette.ink)
                        Text("无需登录 · 数据只保存在这台 iPhone").font(.system(size: 11)).foregroundStyle(palette.muted)
                    }
                }
                .padding(.top, 16)

                sectionTitle("外观", palette)
                VStack(spacing: 0) {
                    Picker("外观", selection: $appearance) {
                        ForEach(AppearanceMode.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                    .padding(14)
                }
                .background(palette.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                sectionTitle("自动记账", palette)
                row("自动记账状态", "App 动作、最近接收、接收日志", "bolt.badge.automatic", palette) { showStatus = true }
                row("使用说明与限制", "支持范围、需要你手动完成的步骤", "questionmark.circle", palette) { showHelp = true }

                sectionTitle("隐私与数据", palette)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("原始通知保留", systemImage: "clock.arrow.circlepath").font(.system(size: 14, weight: .medium)).foregroundStyle(palette.ink)
                        Spacer()
                        Picker("保留", selection: $retention) {
                            Text("7 天").tag(7)
                            Text("30 天").tag(30)
                            Text("90 天").tag(90)
                        }
                        .pickerStyle(.menu)
                    }
                    Text("短信 / 邮件原文只保存在本机，用于核对和处理待处理项；到期后自动清空正文，流水和去重指纹保留。验证码正文从不保存。")
                        .font(.system(size: 11)).foregroundStyle(palette.muted)
                }
                .padding(14)
                .background(palette.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                sectionTitle("开发与调试", palette)
                row("性能开关与调试指标", "单变量对照：玻璃、阴影、遮罩、帧率", "speedometer", palette) { showPerf = true }

                sectionTitle("关于", palette)
                VStack(alignment: .leading, spacing: 4) {
                    Text("日常记账（iOS 原生 Swift 版）").font(.system(size: 14, weight: .medium)).foregroundStyle(palette.ink)
                    Text(BuildInfo.summary).font(.system(size: 11, design: .monospaced)).foregroundStyle(palette.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(palette.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                Color.clear.frame(height: 110)
            }
            .padding(.horizontal, 16)
        }
        .scrollIndicators(.hidden)
        .task { retention = await store.retentionDays() }
        .onChange(of: retention) { _, days in Task { await store.setRetentionDays(days) } }
        .sheet(isPresented: $showStatus) { NavigationStack { AutomationStatusView() } }
        .sheet(isPresented: $showPerf) { NavigationStack { PerformanceSettingsView() } }
        .sheet(isPresented: $showHelp) { NavigationStack { HelpView() } }
    }

    private func sectionTitle(_ title: String, _ palette: Theme) -> some View {
        Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(palette.ink).padding(.top, 24).padding(.bottom, 10)
    }

    private func row(_ title: String, _ subtitle: String, _ symbol: String, _ palette: Theme, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 17)).foregroundStyle(palette.ink).frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 14, weight: .medium)).foregroundStyle(palette.ink)
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(palette.muted)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(palette.muted)
            }
            .padding(14)
            .background(palette.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.bottom, 8)
    }
}

enum BuildInfo {
    static var summary: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        let commit = (info["BKBuildCommit"] as? String).map { String($0.prefix(10)) } ?? "本地构建"
        return "版本 \(version) (\(build)) · \(commit)"
    }
}

/// 自动记账的可观测状态。App 无法读取快捷指令里自动化是否存在或已启用，
/// 这里只展示 App 自己能确认的事实。
struct AutomationStatusView: View {
    @Environment(LedgerStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var log: [IngestLogEntry] = []

    var body: some View {
        List {
            Section {
                Label("已提供 App 动作「记录银行动账通知」", systemImage: "checkmark.circle.fill")
                Label("快捷指令里的自动化是否已创建、已启用：iOS 不向 App 提供查询接口，请在「快捷指令 › 自动化」中查看", systemImage: "questionmark.circle")
                    .font(.footnote)
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
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("待验证 · 尚未收到这张卡的自动输入").font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
            }
            Section {
                if log.isEmpty { Text("还没有收到任何输入").foregroundStyle(.secondary) }
                ForEach(log) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(entry.detail.isEmpty ? entry.classification.displayName : entry.detail).font(.subheadline)
                            Spacer()
                            Text(entry.source.displayName).font(.caption).foregroundStyle(.secondary)
                        }
                        Text("处理于 \(Fmt.dateTime(entry.processedAt))" + (entry.receivedAt.map { " · 接收于 \(Fmt.dateTime($0))" } ?? " · 系统未提供接收时间"))
                            .font(.caption2).foregroundStyle(.secondary)
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
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        .task { log = await store.ingestLog() }
        .refreshable { await store.refresh(); log = await store.ingestLog() }
    }
}

struct PerformanceSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable private var flags = PerfFlags.shared

    var body: some View {
        Form {
            Section {
                Picker("底栏与按钮背景", selection: $flags.chrome) {
                    ForEach(PerfFlags.Chrome.allCases) { Text($0.title).tag($0) }
                }
                Toggle("卡片阴影", isOn: $flags.cardShadows)
                Toggle("卡面合成为位图（drawingGroup）", isOn: $flags.rasterizeCards)
                Toggle("转场遮挡遮罩", isOn: $flags.flightMask)
                Toggle("加号水滴高光", isOn: $flags.dropletHighlight)
            } header: {
                Text("单变量开关")
            } footer: {
                Text("一次只改一个开关，其余保持默认，在同一台 iPhone 上重复同一操作并录屏对照。")
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
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
    }
}
