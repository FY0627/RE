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
                VStack(alignment: .leading, spacing: 6) {
                    Text("只需设置一次").font(.title2.weight(.bold))
                    Text("一个自动化覆盖所有银行卡。收到含「\(Self.keyword)」的短信时，快捷指令在后台把它交给日常记账，不会打开 App。")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
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
            } footer: {
                Text("完成后不用再打开 App。收到下一条银行短信后，下方状态会变成「已验证」。")
            }

            statusSection

            Section {
                DisclosureGroup("可选：也记录银行邮件", isExpanded: $showEmail) {
                    ForEach(Array(Self.emailSteps.enumerated()), id: \.offset) { index, step in
                        StepRow(number: index + 1, text: step)
                    }
                    Text("邮件要进入 iPhone 自带的「邮件」App；邮件自动化只能按发件人、主题筛选，不能按正文筛选。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } footer: {
                Text("银行短信里没有「\(Self.keyword)」两个字时，再建一个同样的自动化，把关键词换成短信里固定出现的字（例如「尾号」）。重复触发不会重复记账。")
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
        } footer: {
            Text("App 读不到自动化是否已开启，只能显示是否真的收到过通知。")
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

private struct StepRow: View {
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
            Section("支持记录的资金变动") {
                Text("消费、工资及其他入账、转入转出、退款、还款、扣息、手续费（含「含手续费」拆分）、存取款、利息、冲正/撤销，以及写明方向和金额的其他变动。")
                Text("预授权、冻结单独显示状态，不计入收支；支付失败保留记录但不计入。")
            }
            Section("不会记成交易") {
                Text("验证码（正文不保存）、营销信息、还款/账单/扣款提醒、电子账单、信用额度变化、只有余额没有交易的通知（只更新银行通知余额）、既没有金额也没有尾号的普通短信（只记在接收日志里）。")
            }
            Section("通知格式") {
                Text("规则基于中国大陆主要银行短信的常见写法（尾号、金额、余额、摘要等字段）和常见英文银行通知格式，测试样例为按公开格式构造的脱敏文本，尚未用每家银行的真实通知逐一验证。识别不了的通知进入待处理。")
            }
            Section("余额") {
                Text("「银行通知余额」只来自银行通知；「初始余额」是你在卡片详情里填写的数。推算余额从两者中较晚的一个出发，加上之后入账的流水。两者都没有时显示余额未知。")
            }
            Section("自动化的运行方式") {
                Text("成功入账默认静默，不会打开 App、不会切换你当前正在用的 App，锁屏时也不会点亮界面。快捷指令可能显示系统自己的运行通知，可在该自动化中关闭「运行时通知」。")
                Text("App 只能处理系统实际交给它的内容：关机、系统未触发或邮件未同步时收不到，事后也无法自动补回。")
                Text("使用免费 Apple 账户签名时，App 约 7 天到期；到期后 App 打不开，自动化也会失败，续签后恢复。")
            }
            Section("数据") {
                Text("账户、流水、规则和设置只保存在本机 SQLite 数据库，无服务器、无云同步、无需注册登录。日志不包含正文与金额。")
            }
        }
        .navigationTitle("使用说明与限制")
        .navigationBarTitleDisplayMode(.inline)
    }
}
