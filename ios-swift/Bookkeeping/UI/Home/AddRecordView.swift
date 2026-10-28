import SwiftUI
import BKModel
import BKBackend

/// 手动记一笔：现金、电子钱包，或者通知还没接上的消费。
/// 顺序：金额 → 分类 → 备注（选填）→ 账户（默认上次用的）→ 保存。转帐选从哪个账户转到哪个账户，转进信用卡算还款。
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
                    TextField("0.00", text: $amountText)
                        .keyboardType(.decimalPad)
                        .font(.system(.largeTitle, design: .rounded).weight(.bold).monospacedDigit())
                        .focused($amountFocused)
                    CurrencyLink(title: "币种", currency: $currency)
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
                // 换了账户：币种跟着换成它的主币种
                if let account = accounts.first(where: { $0.id == accountID }) { currency = account.currency }
                if toAccountID == accountID { toAccountID = nil }
            }
            .onChange(of: type) {
                if let category = store.categoryTree.category(categoryID), category.type != CategoryType(type) { categoryID = nil }
            }
            .task {
                guard accountID == nil else { return }
                let last = await store.lastManualAccountID()
                accountID = accounts.first(where: { $0.id == last })?.id ?? accounts.first?.id
                amountFocused = true
            }
        }
    }

    private var similarMessage: String {
        guard let row = similar.first else { return "" }
        return "\(Fmt.dateTime(row.record.effectiveAt))「\(row.title)」\(row.amountText(inAccount: true))，同一个账户、同样的金额。"
    }

    private func entry() -> ManualEntry? {
        guard let accountID, let currency else { return nil }
        guard case .valid(let amount) = MoneyInput.parse(amountText, negative: false, currency: currency), amount > 0 else {
            errorText = "请填写大于 0 的金额，例如 38.50"
            return nil
        }
        if type == .transfer, toAccountID == nil {
            errorText = "请选择转到哪个账户"
            return nil
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
