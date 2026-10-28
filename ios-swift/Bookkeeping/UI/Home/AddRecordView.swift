import SwiftUI
import BKModel
import BKBackend

/// 手动记一笔：现金、电子钱包，或者通知还没接上的消费。
/// 顺序：金额 → 分类 → 备注（选填）→ 账户（默认上次用的）→ 保存。转帐选从哪个账户转到哪个账户，转进信用卡算还款。
/// 币种只能选这个账户有的（转帐是两个账户都有的），不会在没有日元的卡上记一笔日元转帐。
/// 保存前查一下同一个账户前后 3 小时有没有同样金额的记录（多半是自动记账已经记过了），有就先问一句。
struct AddRecordView: View {
    @Environment(LedgerStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var type: EntryType = .expense
    @State private var amountText = ""
    @State private var currency: CurrencyCode?
    @State private var categoryID: String?
    @State private var note = ""
    @State private var accountID: String?
    @State private var toAccountID: String?
    @State private var counterparty = ""
    @State private var time = Date()
    @State private var saving = false
    @State private var errorText: String?
    @State private var similar: [RecordRow] = []
    @State private var confirmSimilar = false
    @FocusState private var amountFocused: Bool

    private var accounts: [Account] { store.accounts }

    /// 能选的币种：账户有的币种；转帐时两个账户都有的
    private var currencyChoices: [CurrencyCode] {
        guard let account = accounts.first(where: { $0.id == accountID }) else { return [] }
        guard type == .transfer, let target = accounts.first(where: { $0.id == toAccountID }) else { return account.currencies }
        return account.currencies.filter(target.currencies.contains)
    }

    var body: some View {
        NavigationStack {
            Form {
                if accounts.isEmpty {
                    Section {
                        Text("先在资产页添加一个账户（银行卡、现金或电子钱包）。").foregroundStyle(.secondary)
                    }
                }
                Section {
                    Picker("类型", selection: $type) {
                        ForEach(EntryType.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    TextField(MoneyInput.placeholder(currency), text: $amountText)
                        .keyboardType(currency?.minorUnitExponent == 0 ? .numberPad : .decimalPad)
                        .font(.system(.largeTitle, design: .rounded).weight(.bold).monospacedDigit())
                        .focused($amountFocused)
                    CurrencyChoiceRow(choices: currencyChoices, currency: $currency)
                } footer: {
                    if type == .transfer, toAccountID != nil, currencyChoices.isEmpty {
                        Text("这两个账户没有相同的币种，不能直接转帐。").foregroundStyle(.red)
                    }
                }
                if type != .transfer {
                    Section("分类") {
                        CategoryGrid(type: CategoryType(type), selected: categoryID) { categoryID = $0 }
                            .padding(.vertical, 6)
                    }
                }
                Section("备注") {
                    TextField("写点什么，比如买了什么（选填）", text: $note, axis: .vertical)
                        .lineLimit(1...5)
                }
                Section {
                    Picker(type == .transfer ? "从" : "账户", selection: $accountID) {
                        ForEach(accounts) { Text($0.displayTitle).tag(String?.some($0.id)) }
                    }
                    if type == .transfer {
                        Picker("转到", selection: $toAccountID) {
                            Text("请选择").tag(String?.none)
                            ForEach(accounts.filter { $0.id != accountID }) { Text($0.displayTitle).tag(String?.some($0.id)) }
                        }
                    } else {
                        TextField("商户或对方（选填）", text: $counterparty)
                    }
                    DatePicker("时间", selection: $time)
                }
                if let errorText {
                    Section { Text(errorText).foregroundStyle(.red) }
                }
            }
            .navigationTitle("记一笔")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消", systemImage: "xmark") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", systemImage: "checkmark") { Task { await check() } }
                        .disabled(saving || accountID == nil || currency == nil)
                }
            }
            .confirmationDialog("可能已经记过了", isPresented: $confirmSimilar, titleVisibility: .visible) {
                Button("仍然记一笔") { Task { await save() } }
                Button("不记了", role: .cancel) {}
            } message: {
                Text(similarMessage)
            }
            .onChange(of: accountID) {
                if toAccountID == accountID { toAccountID = nil }
                keepCurrencyValid()
            }
            .onChange(of: toAccountID) { keepCurrencyValid() }
            .onChange(of: type) {
                if let category = store.categoryTree.category(categoryID), category.type != CategoryType(type) { categoryID = nil }
                keepCurrencyValid()
            }
            .task {
                guard accountID == nil else { return }
                let last = await store.lastManualAccountID()
                accountID = accounts.first(where: { $0.id == last })?.id ?? accounts.first?.id
                amountFocused = true
            }
        }
    }

    /// 换了账户、类型：币种不在可选的里面了就换成第一个（账户的主币种）
    private func keepCurrencyValid() {
        let choices = currencyChoices
        if let currency, choices.contains(currency) { return }
        currency = choices.first
    }

    private var similarMessage: String {
        guard let row = similar.first else { return "" }
        return "\(Fmt.dateTime(row.record.effectiveAt))「\(row.title)」\(row.amountText(inAccount: true))，同一个账户、同样的金额。"
    }

    private func entry() -> ManualEntry? {
        guard let accountID, let currency else { return nil }
        guard case .valid(let amount) = MoneyInput.parse(amountText, negative: false, currency: currency), amount > 0 else {
            errorText = MoneyInput.invalidAmountMessage(currency)
            return nil
        }
        if type == .transfer {
            guard toAccountID != nil else {
                errorText = "请选择转到哪个账户"
                return nil
            }
            guard currencyChoices.contains(currency) else {
                errorText = "这两个账户没有相同的币种，不能直接转帐。"
                return nil
            }
        }
        return ManualEntry(
            type: type, accountID: accountID, toAccountID: type == .transfer ? toAccountID : nil, amountMinor: amount, currency: currency,
            categoryID: type == .transfer ? nil : categoryID, counterparty: type == .transfer ? nil : counterparty, note: note, time: time
        )
    }

    /// 先查一下是不是已经记过
    private func check() async {
        guard let entry = entry() else { return }
        similar = await store.similarRecords(to: entry)
        if similar.isEmpty {
            await save()
        } else {
            confirmSimilar = true
        }
    }

    private func save() async {
        guard let entry = entry() else { return }
        saving = true
        defer { saving = false }
        do {
            try await store.addRecord(entry)
            dismiss()
        } catch {
            errorText = "保存失败：\(error.localizedDescription)"
        }
    }
}
