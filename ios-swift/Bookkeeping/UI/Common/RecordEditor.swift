import SwiftUI
import BKModel
import BKBackend

/// 修改一笔流水：支出 / 收入 / 转帐、金额、币种、分类、账户、交易对方、时间、备注。
/// 支出可以标成退款（从支出里减掉）；转帐选这张卡是转出还是转入，以及另一边是哪个账户（转到 / 来自）。
/// 交易性质和方向按选的类型换，尽量保留原来的。
/// 币种只列这个账户有的（加上这笔原来的币种）；卡里没有这笔流水的币种时（银行按主币种结汇扣款），
/// 还可以填实际扣了多少主币种，不填就按交易当天的汇率估算。
/// 余额从「校准余额」那一刻算起：比它早的流水换账户、改金额，卡上的余额不变，这时在账户下面写明。
struct RecordEditor: View {
    let detail: RecordDetail
    let onSaved: () -> Void

    @Environment(LedgerStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var type: EntryType
    @State private var refund: Bool
    @State private var transferDirection: FlowDirection
    @State private var amountText: String
    @State private var currency: CurrencyCode?
    @State private var categoryID: String?
    @State private var accountID: String
    @State private var counterparty: String
    @State private var time: Date
    @State private var timeChanged = false
    @State private var note: String
    @State private var settlementText: String
    @State private var peer: PeerChoice
    @State private var saving = false
    @State private var errorText: String?

    /// 转帐的另一边
    enum PeerChoice: Hashable {
        /// 自己的、没添加到 App 的账户
        case untracked
        case account(String)
    }

    private let initialPeer: PeerChoice

    init(detail: RecordDetail, onSaved: @escaping () -> Void) {
        self.detail = detail
        self.onSaved = onSaved
        let r = detail.row.record
        _type = State(initialValue: r.entryType)
        _refund = State(initialValue: r.isRefund)
        _transferDirection = State(initialValue: r.direction)
        _amountText = State(initialValue: MoneyInput.editingText(r.amountMinor, currency: r.currency))
        _currency = State(initialValue: r.currency)
        _categoryID = State(initialValue: r.categoryID)
        _accountID = State(initialValue: r.accountID)
        _counterparty = State(initialValue: r.counterparty ?? "")
        _time = State(initialValue: Self.initialTime(r))
        _note = State(initialValue: r.note)
        _settlementText = State(initialValue: r.settlement.map { MoneyInput.editingText($0.minorUnits, currency: $0.currency) } ?? "")
        let peer = detail.transferPeer.map { PeerChoice.account($0.record.accountID) } ?? PeerChoice.untracked
        _peer = State(initialValue: peer)
        initialPeer = peer
    }

    /// 通知里写了完整的日期和时间就用它（按手机所在时区），否则用收到通知的时间
    private static func initialTime(_ r: LedgerRecord) -> Date {
        if let t = r.transactionTime, let year = t.year, let month = t.month, let day = t.day, let hour = t.hour, let minute = t.minute,
           let date = Calendar.current.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)) {
            return date
        }
        return r.effectiveAt
    }

    private var account: Account? { store.account(id: accountID) }

    /// 可以记到的账户：使用中的账户，加上这笔流水原来的账户（可能已停用）
    private var accounts: [Account] {
        var list = store.accounts
        if let current = store.account(id: detail.row.record.accountID), !list.contains(where: { $0.id == current.id }) {
            list.append(current)
        }
        return list
    }

    /// 账户能用的币种：账户有的币种，加上这笔原来的币种（在原来的账户上时，外币消费保持原样）
    private var allowedCurrencies: [CurrencyCode] {
        guard let account else { return [] }
        let r = detail.row.record
        var codes = account.currencies
        if account.id == r.accountID, !codes.contains(r.currency) { codes.append(r.currency) }
        return codes
    }

    /// 列出来的币种：再加上现在选着的（换账户的那一刻还没换过来时，选择框里也有它）
    private var currencyChoices: [CurrencyCode] {
        var codes = allowedCurrencies
        if let currency, !codes.contains(currency) { codes.append(currency) }
        return codes
    }

    /// 转帐另一边可选的账户：除了这一笔的账户；原来的另一边已停用也列出来
    private var peerOptions: [Account] {
        var list = accounts.filter { $0.id != accountID }
        if case .account(let id) = initialPeer, id != accountID, !list.contains(where: { $0.id == id }), let old = store.account(id: id) {
            list.append(old)
        }
        return list
    }

    private var peerAccount: Account? {
        guard case .account(let id) = peer else { return nil }
        return store.account(id: id)
    }

    /// 比账户的校准余额早、不影响余额的账户（换了账户时才提示）
    private var balanceNote: String? {
        let r = detail.row.record
        guard accountID != r.accountID else { return nil }
        let unaffected = [store.account(id: r.accountID), account].compactMap { $0 }.filter { a in
            guard let opening = a.openingBalance(a.currencies.contains(r.currency) ? r.currency : a.currency) else { return false }
            return (timeChanged ? time : r.effectiveAt) <= opening.at
        }
        guard !unaffected.isEmpty else { return nil }
        return "这笔比「\(unaffected.map(\.displayTitle).joined(separator: "」「"))」的校准余额早，换账户不会改变它的余额（余额从校准那一刻算起）。"
    }

    /// 卡里没有这个币种：要按主币种扣款
    private var settlementCurrency: CurrencyCode? {
        guard let account, let currency, !account.currencies.contains(currency) else { return nil }
        return account.currency
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("类型", selection: $type) {
                        ForEach(EntryType.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if type == .expense {
                        Toggle("退款（从支出里减掉）", isOn: $refund)
                    }
                    if type == .transfer {
                        Picker("这张卡", selection: $transferDirection) {
                            Text("转出").tag(FlowDirection.outflow)
                            Text("转入").tag(FlowDirection.inflow)
                        }
                        Picker(transferDirection == .outflow ? "转到" : "来自", selection: $peer) {
                            ForEach(peerOptions) { Text($0.displayTitle).tag(PeerChoice.account($0.id)) }
                            Text("没添加到 App 的账户").tag(PeerChoice.untracked)
                        }
                    }
                    HStack {
                        Text("金额")
                        TextField(MoneyInput.placeholder(currency), text: $amountText)
                            .keyboardType(currency?.minorUnitExponent == 0 ? .numberPad : .decimalPad)
                            .multilineTextAlignment(.trailing)
                            .font(.title3.weight(.semibold).monospacedDigit())
                    }
                    CurrencyChoiceRow(choices: currencyChoices, currency: $currency)
                    if let settlementCurrency {
                        HStack {
                            Text("实际扣款（\(settlementCurrency.chineseName)）")
                            TextField(settlementPlaceholder(settlementCurrency), text: $settlementText)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .font(.body.monospacedDigit())
                        }
                    }
                }
                if type != .transfer {
                    Section("分类") {
                        CategoryGrid(type: CategoryType(type), selected: categoryID) { categoryID = $0 }
                            .padding(.vertical, 6)
                    }
                }
                Section("备注") {
                    TextField("写点什么，比如买了什么", text: $note, axis: .vertical)
                        .lineLimit(1...5)
                }
                Section {
                    Picker("账户", selection: $accountID) {
                        ForEach(accounts) { Text($0.displayTitle).tag($0.id) }
                    }
                    TextField("交易对方（选填）", text: $counterparty)
                    DatePicker("时间", selection: $time)
                        .onChange(of: time) { timeChanged = true }
                } footer: {
                    if let balanceNote { Text(balanceNote) }
                }
                if let errorText {
                    Section { Text(errorText).foregroundStyle(.red) }
                }
            }
            .navigationTitle("编辑流水")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消", systemImage: "xmark") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", systemImage: "checkmark") { Task { await save() } }
                        .disabled(saving || currency == nil)
                }
            }
            .onChange(of: type) {
                // 支出换成收入（或反过来）：原来的分类对不上了
                if let category = store.categoryTree.category(categoryID), category.type != CategoryType(type) { categoryID = nil }
            }
            .onChange(of: accountID) {
                // 换了账户：另一边不能是它自己；币种换成新账户有的
                if peer == .account(accountID) { peer = .untracked }
                if let currency, allowedCurrencies.contains(currency) { return }
                currency = account?.currency
            }
        }
    }

    /// 没改币种、金额和卡时提示按汇率估算的金额
    private func settlementPlaceholder(_ settlementCurrency: CurrencyCode) -> String {
        let r = detail.row.record
        if let charge = detail.row.charge, !charge.isActual, let estimate = charge.amountMinor, charge.currency == settlementCurrency,
           currency == r.currency, accountID == r.accountID, MoneyInput.parse(amountText, negative: false, currency: currency) == .valid(r.amountMinor) {
            return "约 " + Fmt.money(estimate, settlementCurrency)
        }
        return "不填按汇率估算"
    }

    private func save() async {
        guard let currency else { return }
        guard case .valid(let amount) = MoneyInput.parse(amountText, negative: false, currency: currency), amount > 0 else {
            errorText = MoneyInput.invalidAmountMessage(currency)
            return
        }
        if type == .transfer, let peerAccount {
            guard account?.currencies.contains(currency) == true, peerAccount.currencies.contains(currency) else {
                errorText = "「\(peerAccount.displayTitle)」或这个账户没有\(currency.chineseName)，不能这样转帐。"
                return
            }
        }
        var settlement: Int64?
        if let settlementCurrency {
            switch MoneyInput.parse(settlementText, negative: false, currency: settlementCurrency) {
            case .empty: settlement = nil
            case .valid(let minor) where minor > 0: settlement = minor
            default:
                errorText = "实际扣款的格式不对，例如 78.50"
                return
            }
        }
        let fields = RecordEdit.fields(
            for: type, refund: refund, transferDirection: transferDirection, original: detail.row.record,
            accountIsCredit: account?.cardType == .credit
        )
        let trimmed = counterparty.trimmingCharacters(in: .whitespacesAndNewlines)
        // 转帐的另一边：改了才传（没改时保持原来的配对，手动补记的那边跟着改金额）
        var peerChange = TransferPeerChange.keep
        if type == .transfer, peer != initialPeer || detail.row.entryType != .transfer {
            switch peer {
            case .untracked: peerChange = .untracked
            case .account(let id): peerChange = .account(id)
            }
        }
        let edit = RecordEdit(
            accountID: accountID, amountMinor: amount, currency: currency, direction: fields.direction, kind: fields.kind,
            counterparty: trimmed.isEmpty ? nil : trimmed, time: timeChanged ? time : nil, note: note,
            settlementMinor: settlement, categoryID: type == .transfer ? nil : categoryID, keepsCategory: false, transferParty: fields.party,
            peer: peerChange
        )
        saving = true
        defer { saving = false }
        do {
            try await store.updateRecord(id: detail.row.record.id, edit)
            onSaved()
            dismiss()
        } catch {
            errorText = "保存失败：\(error.localizedDescription)"
        }
    }
}
