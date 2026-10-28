import SwiftUI
import BKModel
import BKBackend

/// 修改一笔流水：支出 / 收入、金额、币种、类型、账户、交易对方、时间、备注。
/// 卡里没有这笔流水的币种时（银行按主币种结汇扣款），还可以填实际扣了多少主币种；不填就按交易当天的汇率估算。
struct RecordEditor: View {
    let detail: RecordDetail
    let onSaved: () -> Void

    @Environment(LedgerStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var direction: FlowDirection
    @State private var amountText: String
    @State private var currency: CurrencyCode?
    @State private var kind: TransactionKind
    @State private var accountID: String
    @State private var counterparty: String
    @State private var time: Date
    @State private var timeChanged = false
    @State private var note: String
    @State private var settlementText: String
    @State private var saving = false
    @State private var errorText: String?

    init(detail: RecordDetail, onSaved: @escaping () -> Void) {
        self.detail = detail
        self.onSaved = onSaved
        let r = detail.row.record
        _direction = State(initialValue: r.direction)
        _amountText = State(initialValue: MoneyInput.editingText(r.amountMinor, currency: r.currency))
        _currency = State(initialValue: r.currency)
        _kind = State(initialValue: r.kind)
        _accountID = State(initialValue: r.accountID)
        _counterparty = State(initialValue: r.counterparty ?? "")
        _time = State(initialValue: Self.initialTime(r))
        _note = State(initialValue: r.note)
        _settlementText = State(initialValue: r.settlement.map { MoneyInput.editingText($0.minorUnits, currency: $0.currency) } ?? "")
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

    /// 可以记到的卡：使用中的卡，加上这笔流水原来的卡（可能已停用）
    private var accounts: [Account] {
        var list = store.accounts
        if let current = store.account(id: detail.row.record.accountID), !list.contains(where: { $0.id == current.id }) {
            list.append(current)
        }
        return list
    }

    /// 卡里没有这个币种：要按主币种扣款
    private var settlementCurrency: CurrencyCode? {
        guard let account, let currency, !account.currencies.contains(currency) else { return nil }
        return account.currency
    }

    /// 支出、收入各自常见的类型
    private static func commonKinds(for direction: FlowDirection) -> [TransactionKind] {
        direction == .outflow
            ? [.purchase, .transferOut, .repayment, .withdrawal, .fee, .interestCharge, .other]
            : [.income, .salary, .transferIn, .refund, .repayment, .deposit, .interestIncome, .reversal, .other]
    }

    /// 选项里保留这笔流水现在的类型（识别出的类型可能不在常见类型里）
    private var kinds: [TransactionKind] {
        var list = Self.commonKinds(for: direction)
        if !list.contains(kind) { list.append(kind) }
        return list
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("收支", selection: $direction) {
                        Text("支出").tag(FlowDirection.outflow)
                        Text("收入").tag(FlowDirection.inflow)
                    }
                    .pickerStyle(.segmented)
                    HStack {
                        Text("金额")
                        TextField("0.00", text: $amountText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .font(.title3.weight(.semibold).monospacedDigit())
                    }
                    CurrencyLink(title: "币种", currency: $currency)
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
                Section {
                    Picker("类型", selection: $kind) {
                        ForEach(kinds, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    Picker("账户", selection: $accountID) {
                        ForEach(accounts) { Text("\($0.bankName) ·\($0.last4)").tag($0.id) }
                    }
                    TextField("交易对方（选填）", text: $counterparty)
                    DatePicker("时间", selection: $time)
                        .onChange(of: time) { timeChanged = true }
                }
                Section("备注") {
                    TextField("添加备注", text: $note, axis: .vertical)
                        .lineLimit(1...5)
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
            .onChange(of: direction) {
                // 收支换了、类型不属于这一边：换成这一边最常见的类型
                if !Self.commonKinds(for: direction).contains(kind) { kind = direction == .outflow ? .purchase : .income }
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
            errorText = "请填写大于 0 的金额，例如 38.50"
            return
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
        let trimmed = counterparty.trimmingCharacters(in: .whitespacesAndNewlines)
        let edit = RecordEdit(
            accountID: accountID, amountMinor: amount, currency: currency, direction: direction, kind: kind,
            counterparty: trimmed.isEmpty ? nil : trimmed, time: timeChanged ? time : nil, note: note,
            settlementMinor: settlement
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
