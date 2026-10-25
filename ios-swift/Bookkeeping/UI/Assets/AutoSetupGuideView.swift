import SwiftUI
import UIKit
import BKModel

/// 「设置自动记账」：一个短信自动化覆盖所有银行卡，只需设置一次。
///
/// iOS 不允许 App 创建、导入或查询快捷指令自动化，分享的快捷指令也不带自动化触发器，
/// 所以这里给出最少的手动步骤，并只展示 App 能确认的状态（是否收到过真实输入）。
/// 自动化按关键词「银行」触发；正文里的尾号由 App 匹配到具体的卡，不需要每张卡各建一个。
struct AutoSetupGuideView: View {
    /// 从某张卡进入时显示这张卡的验证状态
    var account: Account?
    /// 作为面板或添加流程的最后一步出现时，右上角显示「完成」
    var onDone: (() -> Void)?

    static let keyword = "银行"

    @Environment(LedgerStore.self) private var store
    @Environment(\.openURL) private var openURL
    @State private var copied = false
    @State private var showEmail = false

    var body: some View {
        List {
            Section {
                Text("只需设置一次").font(.title2.weight(.bold))
                    .padding(.vertical, 4)
                HStack(spacing: 12) {
                    Button {
                        UIPasteboard.general.string = Self.keyword
                        copied = true
                    } label: {
                        Label(copied ? "已复制" : "复制「\(Self.keyword)」", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                    Button {
                        if let url = URL(string: "shortcuts://") { openURL(url) }
                    } label: {
                        Label("打开快捷指令", systemImage: "arrow.up.forward.app")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                }
                .controlSize(.large)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }

            Section {
                ForEach(Array(Self.smsSteps.enumerated()), id: \.offset) { index, step in
                    StepRow(number: index + 1, text: step)
                }
            } header: {
                Text("5 步完成")
            }

            statusSection

            Section {
                DisclosureGroup("可选：也记录银行邮件", isExpanded: $showEmail) {
                    ForEach(Array(Self.emailSteps.enumerated()), id: \.offset) { index, step in
                        StepRow(number: index + 1, text: step)
                    }
                }
            }
        }
        .navigationTitle("设置自动记账")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if let onDone {
                    Button("完成", systemImage: "checkmark", action: onDone)
                }
            }
        }
        // 添加银行卡后紧接着出现时不显示返回（卡已经保存，返回会回到已提交的表单）
        .navigationBarBackButtonHidden(onDone != nil)
    }

    private var statusSection: some View {
        var verified: (account: Account, at: Date)?
        for a in store.accounts {
            if let at = store.automation[a.id]?.lastSuccessAt, at > (verified?.at ?? .distantPast) { verified = (a, at) }
        }
        return Section {
            if let account {
                let last = store.automation[account.id]?.lastSuccessAt
                StatusRow(
                    title: "\(account.bankName) ·\(account.last4)",
                    detail: last.map { "已验证 · 最近一次接收 \(Fmt.dateTime($0))" } ?? "待验证 · 还没有收到这张卡的自动输入",
                    done: last != nil
                )
            }
            StatusRow(
                title: "自动记账",
                detail: verified.map { "已验证 · 最近一次接收 \(Fmt.dateTime($0.at))（\($0.account.bankName) ·\($0.account.last4)）" } ?? "待验证 · 还没有收到任何银行短信",
                done: verified != nil
            )
        } header: {
            Text("当前状态")
        }
    }

    static let smsSteps: [LocalizedStringKey] = [
        "点上面 **打开快捷指令**，在底部选 **自动化**，点右上角 **+**，选 **信息**。",
        "在 **信息包含** 里粘贴 **银行**，其他条件不用填。",
        "选 **立即运行**，点 **下一步**。",
        "点 **新建空白自动化** → **添加操作**，搜索 **记录银行动账通知** 并添加。",
        "确认动作里的 **通知内容** 显示为 **快捷指令输入**（没有就点它选上），再点 **完成**。",
    ]

    static let emailSteps: [LocalizedStringKey] = [
        "**自动化** → **+** → **电子邮件**，在 **发件人** 里填银行通知邮箱。",
        "选 **立即运行** → **新建空白自动化** → 添加 **记录银行动账通知**。",
        "**通知内容** 选 **快捷指令输入**，**来源** 改为 **邮件**，点 **完成**。",
    ]
}

struct StepRow: View {
    let number: Int
    let text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Color.accentColor, in: Circle())
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
            Text(text).font(.body)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

private struct StatusRow: View {
    let title: String
    let detail: String
    let done: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "clock")
                .font(.title3)
                .foregroundStyle(done ? Color.green : Color.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct HelpView: View {
    var body: some View {
        List {
            Section("会记录") {
                Text("消费、收入、转账、退款、还款、利息、手续费、存取款、冲正。")
            }
            Section("不会记录") {
                Text("验证码、营销、提醒、账单、额度变化、只有余额的通知。")
            }
            Section("识别不了的") {
                Text("进入「待处理」，由你确认或忽略。")
            }
            Section("数据") {
                Text("只保存在这台 iPhone。默认不联网；打开「联网获取汇率」后只下载公开汇率。")
            }
        }
        .navigationTitle("使用说明")
        .navigationBarTitleDisplayMode(.inline)
    }
}
