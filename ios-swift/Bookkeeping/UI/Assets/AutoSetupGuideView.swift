import SwiftUI
import UIKit
import AppIntents
import BKModel

/// 「设置自动记账」：跳转系统快捷指令完成添加。
///
/// iOS 不允许 App 创建、导入或查询快捷指令自动化，分享的快捷指令也不带自动化触发器，
/// 所以这里给出最少步骤，并只展示 App 能确认的状态（是否收到过真实输入）。
struct AutoSetupGuideView: View {
    let account: Account
    var onDone: (() -> Void)?

    enum Channel: String, CaseIterable, Identifiable {
        case sms
        case email
        var id: String { rawValue }
        var title: String { self == .sms ? "短信" : "邮件" }
    }

    @Environment(LedgerStore.self) private var store
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    @State private var channel: Channel = .sms
    @State private var copied = false

    private var bank: BankProfile? { BankDirectory.profile(id: account.bankID) }

    var body: some View {
        List {
            statusSection
            Section {
                Picker("通知渠道", selection: $channel) {
                    ForEach(Channel.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
            }
            Section {
                Button {
                    UIPasteboard.general.string = account.last4
                    copied = true
                } label: {
                    Label(copied ? "已复制尾号 \(account.last4)" : "复制尾号 \(account.last4)", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                Button {
                    if let url = URL(string: "shortcuts://") { openURL(url) }
                } label: {
                    Label("打开「快捷指令」", systemImage: "arrow.up.forward.app")
                }
                ShortcutsLink()
                    .shortcutsLinkStyle(.automaticOutline)
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
            } footer: {
                Text("打开快捷指令只是开始配置，不代表自动记账已经启用。")
            }
            Section("步骤") {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .top, spacing: 10) {
                        Text("\(index + 1)").font(.footnote.weight(.bold)).frame(width: 22, height: 22).background(.quaternary, in: Circle())
                        Text(step).font(.subheadline)
                    }
                    .padding(.vertical, 2)
                }
            }
            Section("说明") {
                ForEach(notes, id: \.self) { Text($0).font(.footnote).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("设置自动记账")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("完成") { if let onDone { onDone() } else { dismiss() } }
            }
        }
        .navigationBarBackButtonHidden(onDone != nil)
    }

    private var statusSection: some View {
        let status = store.automation[account.id]
        return Section {
            row("App 动作「记录银行动账通知」", "已提供（随 App 安装，快捷指令中可搜索）", done: true)
            row("快捷指令自动化", "App 无法读取是否已创建或启用，请在「快捷指令 › 自动化」中确认", done: nil)
            if let last = status?.lastSuccessAt {
                row("真实触发验证", "已验证 · 最近一次接收 \(Fmt.dateTime(last))（\(status?.lastSuccessSource?.displayName ?? "")）· 累计 \(status?.receivedCount ?? 0) 次", done: true)
            } else {
                row("真实触发验证", "待验证 · 还没有收到 \(account.bankName) ·\(account.last4) 的自动输入", done: false)
            }
        } header: {
            Text("\(account.bankName) ·\(account.last4) 当前状态")
        }
    }

    private func row(_ title: String, _ detail: String, done: Bool?) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: done == true ? "checkmark.circle.fill" : done == false ? "clock" : "questionmark.circle")
                .foregroundStyle(done == true ? Color.green : done == false ? Color.orange : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var steps: [String] {
        let accountName = "\(account.bankName) ·\(account.last4)"
        switch channel {
        case .sms:
            let number = bank?.smsNumbers.first.map { "（例如 \($0)，以你实际收到的为准）" } ?? ""
            return [
                "点上方「复制尾号」，再点「打开『快捷指令』」。",
                "在底部选「自动化」，点「+」新建个人自动化，选择「信息」。",
                "在「信息包含」里粘贴 \(account.last4)。这是按短信正文筛选：只有正文含这个尾号的短信才会触发。也可以再在「发件人」里选银行短信号码\(number)；同时设置时两个条件都要满足。",
                "选择「立即运行」（不要选「运行前确认」）。如不想看到系统的运行通知，可关闭「运行时通知」。点「下一步」。",
                "选「新建空白自动化」→「添加操作」，搜索「日常记账」，选择「记录银行动账通知」。",
                "点操作里的「通知内容」，选变量「快捷指令输入」（如出现属性列表，选「内容」）。「来源」保持「短信」。",
                "点「›」展开更多参数：「绑定账户」选「\(accountName)」；如变量菜单提供「发件人」，可填到「发件人」。没有的项目留空即可，不要手填。",
                "点「完成」。之后不需要打开记账 App。收到下一条该卡的银行短信后回到这里，状态会变为「已验证」。",
            ]
        case .email:
            let domain = bank?.emailDomains.first.map { "（常见域名如 @\($0)，以你实际收到的邮件为准）" } ?? ""
            return [
                "确认银行动账邮件会进入 iPhone 自带的「邮件」App（第三方邮件 App 不会触发此自动化）。",
                "打开「快捷指令」→「自动化」→「+」，选择「电子邮件」。",
                "在「发件人」里添加银行通知邮件的发件地址\(domain)；可再加「主题包含」，例如「交易提醒」。邮件触发器只能按发件人、主题、账户、收件人筛选，不能按正文筛选。",
                "选择「立即运行」，点「下一步」→「新建空白自动化」→ 添加「记录银行动账通知」。",
                "「通知内容」选「快捷指令输入」；「来源」改为「邮件」。",
                "展开更多参数：如变量菜单提供「主题」「发件人」「接收日期」「邮件 ID」，可分别填入；没有就留空。「绑定账户」可选「\(accountName)」。",
                "点「完成」。App 会在入账时检查正文里的尾号：尾号与这张卡不一致的邮件不会记到这张卡上，无法确定时进入待处理。",
            ]
        }
    }

    private var notes: [String] {
        [
            "成功入账默认静默，不会打开 App、不会切换你当前正在用的 App，锁屏时也不会点亮界面。",
            "快捷指令可能显示系统自己的「正在运行自动化」通知或首次授权提示，这是系统行为，不是 App 弹窗；可在该自动化中关闭「运行时通知」。",
            "解析、入账都在本机完成，不需要网络。短信、邮件本身的送达仍需要运营商或邮件服务。",
            "App 只能处理系统实际交给它的内容：关机、系统未触发或邮件未同步时收不到，事后也无法自动补回；不能保证银行发送了每一笔通知。",
            "无法确定的通知会进入「待处理」，不会被静默丢弃。",
            "使用免费 Apple 账户签名时，App 约 7 天到期；到期后 App 打不开，自动化也会失败，续签后恢复。",
        ]
    }
}

struct HelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section("支持记录的资金变动") {
                Text("消费、工资及其他入账、转入转出、退款、还款、扣息、手续费（含「含手续费」拆分）、存取款、利息、冲正/撤销，以及写明方向和金额的其他变动。")
                Text("预授权、冻结单独显示状态，不计入收支；支付失败保留记录但不计入。")
            }
            Section("不会记成交易") {
                Text("验证码（正文不保存）、营销信息、还款/账单/扣款提醒、电子账单、信用额度变化、只有余额没有交易的通知（只更新银行通知余额）。")
            }
            Section("通知格式") {
                Text("规则基于中国大陆主要银行短信的常见写法（尾号、金额、余额、摘要等字段）和常见英文银行通知格式，测试样例为按公开格式构造的脱敏文本，尚未用每家银行的真实通知逐一验证。识别不了的通知进入待处理。")
            }
            Section("需要你在 iPhone 上完成") {
                Text("1. 用 Sideloadly 安装并信任开发者；2. 在快捷指令里为每张卡创建短信或邮件自动化；3. 等一条真实通知验证。App 无法替你创建自动化，也无法读取自动化是否启用。")
            }
            Section("数据") {
                Text("账户、流水、规则和设置只保存在本机 SQLite 数据库，无服务器、无云同步、无需注册登录。日志不包含正文与金额。")
            }
        }
        .navigationTitle("使用说明与限制")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
    }
}
