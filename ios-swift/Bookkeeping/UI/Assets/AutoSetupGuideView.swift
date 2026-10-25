import SwiftUI
import UIKit
import BKModel

/// 「设置自动记账」：每张卡一个短信自动化，「信息包含」填这张卡的尾号。
///
/// 按尾号触发而不是按「银行」等关键词：繁体（銀行）、英文银行的短信写法各不相同，
/// 而有资金变动的通知都会带卡号尾号。iOS 的信息自动化「信息包含」只能填一个词，所以每张卡建一个。
/// iOS 不允许 App 创建、导入或查询快捷指令自动化，这里只给出最少的手动步骤，
/// 并只展示 App 能确认的状态（是否收到过这张卡的真实输入）。
struct AutoSetupGuideView: View {
    /// 从某张卡进入（例如刚添加完）时把这张卡排在最前面
    var account: Account?
    /// 作为面板或添加流程的最后一步出现时，右上角显示「完成」
    var onDone: (() -> Void)?

    @Environment(LedgerStore.self) private var store
    @Environment(\.openURL) private var openURL
    @State private var copiedTail: String?
    @State private var showEmail = false

    private var cards: [Account] {
        guard let account else { return store.accounts }
        return [account] + store.accounts.filter { $0.id != account.id }
    }

    var body: some View {
        List {
            Section {
                Text("每张卡设置一次").font(.title2.weight(.bold))
                    .padding(.vertical, 4)
                Button {
                    if let url = URL(string: "shortcuts://") { openURL(url) }
                } label: {
                    Label("打开快捷指令", systemImage: "arrow.up.forward.app")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
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

            Section {
                if cards.isEmpty {
                    Text("还没有银行卡").foregroundStyle(.secondary)
                }
                ForEach(cards) { card in
                    cardRow(card)
                }
            } header: {
                Text("点尾号复制")
            }

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

    /// 一张卡：尾号（点按复制）和是否收到过这张卡的自动输入。
    private func cardRow(_ card: Account) -> some View {
        let last = store.automation[card.id]?.lastSuccessAt
        let copied = copiedTail == card.last4
        return Button {
            UIPasteboard.general.string = card.last4
            copiedTail = card.last4
        } label: {
            HStack(spacing: 12) {
                Image(systemName: last != nil ? "checkmark.circle.fill" : "clock")
                    .font(.title3)
                    .foregroundStyle(last != nil ? Color.green : Color.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(card.displayTitle).font(.body.weight(.medium)).foregroundStyle(.primary)
                    Text(last.map { "最近一次接收 \(Fmt.dateTime($0))" } ?? "还没有收到这张卡的自动输入")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Label(copied ? "已复制" : card.last4, systemImage: copied ? "checkmark" : "doc.on.doc")
                    .font(.body.monospacedDigit().weight(.semibold))
                    .labelStyle(.titleAndIcon)
            }
        }
        .accessibilityLabel("\(card.displayTitle)，尾号 \(card.last4)，\(last != nil ? "已收到过自动输入" : "还没有收到自动输入")")
        .accessibilityHint("复制尾号")
    }

    static let smsSteps: [LocalizedStringKey] = [
        "点上面 **打开快捷指令**，在底部选 **自动化**，点右上角 **+**，选 **信息**。",
        "在 **信息包含** 里粘贴这张卡的 **尾号**（在下面点尾号复制），其他条件不用填。",
        "选 **立即运行**，点 **下一步**。",
        "点 **新建空白自动化** → **添加操作**，搜索 **记录银行动账通知** 并添加。",
        "确认 **通知内容** 显示为 **快捷指令输入**（没有就点它选上），点 **完成**。每张卡重复一次。",
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
                Text("只保存在这台 iPhone，App 不联网。汇率由快捷指令下载后导入。")
            }
        }
        .navigationTitle("使用说明")
        .navigationBarTitleDisplayMode(.inline)
    }
}
