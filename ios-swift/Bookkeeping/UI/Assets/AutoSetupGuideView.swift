import SwiftUI
import UIKit
import BKModel

/// 「设置自动记账」：一个自动化，用「信息」「电子邮件」「App 通知」触发（条件都不填），全部交给 App，只需设置一次。
/// 来源选「自动」：App 分不出是哪一种时，同一笔交易的短信、邮件、App 通知合并成一笔或进待处理，不会重复记账。
///
/// 不按关键词或尾号筛选：繁体（銀行）、英文银行写法各不相同，「信息包含」又只能填一个词。
/// 由 App 判断是不是动账通知：认出尾号（固定写法，或正文里出现已添加的卡的尾号）才入账；
/// 不是动账通知的短信不保存。
/// iOS 不允许 App 创建、导入或查询快捷指令自动化，这里只给出最少的手动步骤，
/// 并只展示 App 能确认的状态（是否收到过每张卡的真实输入）。
struct AutoSetupGuideView: View {
    /// 从某张卡进入（例如刚添加完）时把这张卡排在最前面
    var account: Account?
    /// 作为面板或添加流程的最后一步出现时，右上角显示「完成」
    var onDone: (() -> Void)?

    @Environment(LedgerStore.self) private var store
    @Environment(\.openURL) private var openURL

    private var cards: [Account] {
        guard let account else { return store.accounts }
        return [account] + store.accounts.filter { $0.id != account.id }
    }

    var body: some View {
        List {
            Section {
                Text("只需设置一次").font(.title2.weight(.bold))
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

            if !cards.isEmpty {
                Section {
                    ForEach(cards) { card in
                        cardRow(card)
                    }
                } header: {
                    Text("各卡状态")
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

    /// 一张卡是否收到过自动输入
    private func cardRow(_ card: Account) -> some View {
        let last = store.automation[card.id]?.lastSuccessAt
        return HStack(spacing: 12) {
            Image(systemName: last != nil ? "checkmark.circle.fill" : "clock")
                .font(.title3)
                .foregroundStyle(last != nil ? Color.green : Color.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(card.displayTitle).font(.body.weight(.medium))
                Text(last.map { "最近一次接收 \(Fmt.dateTime($0))" } ?? "还没有收到这张卡的自动输入")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    static let smsSteps: [LocalizedStringKey] = [
        "点上面 **打开快捷指令**，在底部选 **自动化**，点右上角 **+**，选 **信息**，条件都不填。",
        "在同一个自动化里再加 **电子邮件** 和 **App 通知** 触发，条件都不填；App 通知可以只选银行 App。",
        "选 **立即运行**，添加操作 **记录银行动账通知**。",
        "**通知内容** 选自动化的输入（显示为 **快捷指令输入** 或 **通知**）。",
        "**来源** 选 **自动**，点 **完成**。不是动账通知的内容不会保存。",
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
