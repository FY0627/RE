import SwiftUI
import BKModel
import BKBackend

/// 添加银行卡：银行（直接输入，下面列出对得上的银行全称，什么语言都能搜）、后四位、卡类型、
/// 币种（可设为多币种账户）和每个币种的初始余额（选填，紧跟在选好的币种下面）。不收集完整卡号、密码或邮箱凭据。
struct AddAccountView: View {
    @Environment(LedgerStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var bankText = ""
    /// 从列表里选中的银行；改了名称就不算选中
    @State private var bank: BankEntry?
    @FocusState private var bankFocused: Bool
    @State private var name = ""
    @State private var last4 = ""
    @State private var cardType: CardType = .debit
    @State private var currency: CurrencyCode?
    @State private var multiCurrency = false
    @State private var extraCurrencies: [CurrencyCode] = []
    @State private var balances: [CurrencyCode: BalanceInput] = [:]
    @State private var paletteID = "ocean"
    @State private var paletteTouched = false
    @State private var saving = false
    @State private var errorText: String?
    @State private var created: Account?

    private var bankName: String { bankText.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// 这张卡的币种，主币种在前
    private var currencies: [CurrencyCode] {
        guard let currency else { return [] }
        return [currency] + (multiCurrency ? extraCurrencies.filter { $0 != currency } : [])
    }

    private var isValid: Bool {
        !bankName.isEmpty && Account.isValidLast4(last4) && currency != nil
            && currencies.allSatisfy { balance($0).wrappedValue.value($0) != .invalid }
    }

    private var suggestions: [BankEntry] {
        bank == nil ? BankCatalog.search(bankText) : []
    }

    /// 没填过的币种：信用卡默认是欠款
    private func balance(_ code: CurrencyCode) -> Binding<BalanceInput> {
        Binding { balances[code] ?? BalanceInput(isDebt: cardType == .credit) } set: { balances[code] = $0 }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("银行") {
                    TextField("银行名称", text: $bankText)
                        .focused($bankFocused)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                    ForEach(suggestions) { entry in
                        Button { choose(entry) } label: { BankSuggestionRow(entry: entry) }
                    }
                }
                Section("卡片") {
                    TextField("卡号后四位", text: $last4)
                        .keyboardType(.numberPad)
                        .onChange(of: last4) { _, value in
                            let digits = String(value.filter { $0.isASCII && $0.isNumber }.prefix(4))
                            if digits != value { last4 = digits }
                        }
                        .accessibilityHint("四位数字，保留开头的 0")
                    Picker("卡类型", selection: $cardType) {
                        ForEach(CardType.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    TextField("账户名称（可选）", text: $name)
                }
                Section("币种与初始余额") {
                    CurrencyLink(title: multiCurrency ? "主币种" : "币种", currency: primaryCurrency)
                    if let currency {
                        OpeningBalanceRow(currency: currency, label: multiCurrency ? currency.chineseName : nil, input: balance(currency))
                    }
                    Toggle("多币种账户", isOn: $multiCurrency)
                    if multiCurrency {
                        NavigationLink {
                            CurrencyPicker(title: "其他币种", selection: $extraCurrencies, multiple: true, fixed: currency)
                        } label: {
                            LabeledContent("其他币种", value: extrasSummary)
                        }
                        ForEach(currencies.dropFirst(), id: \.self) { code in
                            OpeningBalanceRow(currency: code, label: code.chineseName, input: balance(code))
                        }
                    }
                }
                Section("卡面") {
                    PaletteGrid(selection: Binding(get: { paletteID }, set: { paletteID = $0; paletteTouched = true }))
                        .padding(.vertical, 4)
                }
                if let errorText {
                    Section { Text(errorText).foregroundStyle(.red) }
                }
            }
            .keyboardDismissible()
            .navigationTitle("添加银行卡")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消", systemImage: "xmark") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", systemImage: "checkmark") { Task { await save() } }.disabled(!isValid || saving)
                }
            }
            .onChange(of: bankText) { _, text in
                if let bank, text != bank.name { self.bank = nil }
            }
            .onChange(of: cardType) { _, type in
                for (code, input) in balances where input.text.isEmpty { balances[code]?.isDebt = type == .credit }
            }
            .navigationDestination(item: $created) { account in
                AutoSetupGuideView(account: account, onDone: { dismiss() })
            }
            .task {
                // 银行和币种的搜索列表第一次要查系统名称、算拼音，先在后台准备好
                await CurrencyCatalog.prepare()
                await Task.detached(priority: .utility) { _ = BankCatalog.search("银行") }.value
            }
        }
    }

    /// 选主币种：选的是其他币种之一时，和原来的主币种互换
    private var primaryCurrency: Binding<CurrencyCode?> {
        Binding { currency } set: { newValue in
            guard let newValue, newValue != currency else { return }
            if let index = extraCurrencies.firstIndex(of: newValue) {
                if let old = currency { extraCurrencies[index] = old } else { extraCurrencies.remove(at: index) }
            }
            currency = newValue
        }
    }

    private var extrasSummary: String {
        let extras = currencies.dropFirst()
        return extras.isEmpty ? "请选择" : extras.map(\.chineseName).joined(separator: "、")
    }

    private func choose(_ entry: BankEntry) {
        bank = entry
        bankText = entry.name
        bankFocused = false
        if !paletteTouched, let palette = entry.paletteID { paletteID = palette }
    }

    private func save() async {
        guard let currency else { return }
        saving = true
        defer { saving = false }
        // 没点列表、但打的正好是某家银行的名称或叫法：也算选中它
        let entry = bank ?? BankCatalog.exactMatch(bankText)
        var openings: [CurrencyCode: Int64] = [:]
        for code in currencies {
            if case .valid(let minor) = balance(code).wrappedValue.value(code) { openings[code] = minor }
        }
        let draft = AccountDraft(
            name: name, bankID: entry?.id, bankName: entry?.name ?? bankName,
            last4: last4, cardType: cardType, currency: currency, paletteID: paletteID, openingBalanceMinor: openings[currency],
            extraCurrencies: Array(currencies.dropFirst()), extraOpeningBalances: openings.filter { $0.key != currency }
        )
        do {
            let alreadyAutomated = store.automationVerified
            let account = try await store.addAccount(draft)
            errorText = nil
            // 自动化已经在工作：一个自动化覆盖所有卡，新卡不用再设置
            if alreadyAutomated { dismiss() } else { created = account }
        } catch BackendError.invalidAccount(let reason) {
            switch reason {
            case .duplicateAccount: errorText = "已经添加过这张卡（同一银行、同一尾号、同一卡类型）。"
            case .invalidLast4: errorText = "后四位必须是 4 位数字。"
            case .emptyBank, .emptyName: errorText = "请填写银行。"
            case .invalidCardNumber: errorText = "卡号格式不正确。"
            case .invalidAccountNumber: errorText = "账号格式不正确。"
            }
        } catch {
            errorText = "保存失败：\(error)"
        }
    }
}

/// 输入银行名称时列出的一家银行：中文全称，下面是英文或当地名称和地区。
/// 颜色用 `Color.primary` / `Color.secondary`：按钮里的层级样式 `.primary` 会跟着强调色变成蓝色
private struct BankSuggestionRow: View {
    let entry: BankEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.name).foregroundStyle(Color.primary)
            Text(entry.localName == entry.name ? entry.region : "\(entry.localName) · \(entry.region)")
                .font(.footnote)
                .foregroundStyle(Color.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}
