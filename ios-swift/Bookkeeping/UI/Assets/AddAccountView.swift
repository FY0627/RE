import SwiftUI
import BKModel
import BKBackend

/// 添加银行卡：银行、后四位、卡类型、币种（可设为多币种账户），以及选填的初始余额。不收集完整卡号、密码或邮箱凭据。
struct AddAccountView: View {
    struct BalanceInput {
        var text = ""
        var isDebt = false
    }

    @Environment(LedgerStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var bankChoice = ""
    @State private var customBank = ""
    @State private var name = ""
    @State private var last4 = ""
    @State private var cardType: CardType = .debit
    @State private var currency: CurrencyCode?
    @State private var paletteID = "ocean"
    @State private var paletteTouched = false
    @State private var balanceText = ""
    @State private var balanceIsDebt = false
    @State private var multiCurrency = false
    @State private var extraCurrencies: [CurrencyCode] = []
    @State private var extraBalances: [CurrencyCode: BalanceInput] = [:]
    @State private var saving = false
    @State private var errorText: String?
    @State private var created: Account?

    private static let customTag = "__custom"

    private var bankName: String {
        bankChoice == Self.customTag ? customBank.trimmingCharacters(in: .whitespaces) : (BankDirectory.profile(id: bankChoice)?.name ?? "")
    }

    private var isValid: Bool {
        !bankName.isEmpty && Account.isValidLast4(last4) && currency != nil && openingBalance != .invalid
            && selectedExtras.allSatisfy { extraValue($0) != .invalid }
    }

    /// 多币种账户的其他币种（关闭多币种时为空）
    private var selectedExtras: [CurrencyCode] {
        multiCurrency ? extraCurrencies.filter { $0 != currency } : []
    }

    private func extraValue(_ code: CurrencyCode) -> MoneyInput.Value {
        let input = extraBalances[code] ?? BalanceInput()
        return MoneyInput.parse(input.text, negative: input.isDebt, currency: code)
    }

    private func extraText(_ code: CurrencyCode) -> Binding<String> {
        Binding { extraBalances[code]?.text ?? "" } set: { extraBalances[code, default: BalanceInput()].text = $0 }
    }

    private func extraDebt(_ code: CurrencyCode) -> Binding<Bool> {
        Binding { extraBalances[code]?.isDebt ?? false } set: { extraBalances[code, default: BalanceInput()].isDebt = $0 }
    }

    private var openingBalance: MoneyInput.Value {
        MoneyInput.parse(balanceText, negative: balanceIsDebt, currency: currency)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("银行") {
                    Picker("银行", selection: $bankChoice) {
                        Text("请选择").tag("")
                        ForEach(BankDirectory.all) { Text($0.name).tag($0.id) }
                        Text("其他银行").tag(Self.customTag)
                    }
                    if bankChoice == Self.customTag {
                        TextField("银行名称", text: $customBank)
                    }
                }
                Section {
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
                } header: {
                    Text("卡片")
                }
                Section {
                    Picker(multiCurrency ? "主币种" : "币种", selection: $currency) {
                        Text("请选择").tag(CurrencyCode?.none)
                        ForEach(CurrencyCode.common, id: \.self) { code in
                            Text("\(code.chineseName) \(code.rawValue)").tag(CurrencyCode?.some(code))
                        }
                    }
                    Toggle("多币种账户", isOn: $multiCurrency)
                } header: {
                    Text("记账币种")
                }
                if multiCurrency {
                    Section("其他币种") {
                        ExtraCurrencyList(primary: currency, selection: $extraCurrencies)
                    }
                }
                Section {
                    OpeningBalanceFields(text: $balanceText, isDebt: $balanceIsDebt, currency: currency)
                } header: {
                    Text(multiCurrency ? "\(currency?.chineseName ?? "主币种")初始余额（选填）" : "初始余额（选填）")
                }
                ForEach(selectedExtras, id: \.self) { code in
                    Section("\(code.chineseName)初始余额（选填）") {
                        OpeningBalanceFields(text: extraText(code), isDebt: extraDebt(code), currency: code)
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
            .navigationTitle("添加银行卡")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消", systemImage: "xmark") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", systemImage: "checkmark") { Task { await save() } }.disabled(!isValid || saving)
                }
            }
            .onChange(of: cardType) { _, type in
                if balanceText.isEmpty { balanceIsDebt = type == .credit }
            }
            .onChange(of: bankChoice) { _, id in
                if !paletteTouched, let profile = BankDirectory.profile(id: id) { paletteID = profile.defaultPaletteID }
            }
            .navigationDestination(item: $created) { account in
                AutoSetupGuideView(account: account, onDone: { dismiss() })
            }
        }
    }

    private func save() async {
        guard let currency else { return }
        saving = true
        defer { saving = false }
        var opening: Int64?
        if case .valid(let minor) = openingBalance { opening = minor }
        var extraOpenings: [CurrencyCode: Int64] = [:]
        for code in selectedExtras {
            if case .valid(let minor) = extraValue(code) { extraOpenings[code] = minor }
        }
        let draft = AccountDraft(
            name: name, bankID: bankChoice == Self.customTag ? nil : bankChoice, bankName: bankName,
            last4: last4, cardType: cardType, currency: currency, paletteID: paletteID, openingBalanceMinor: opening,
            extraCurrencies: selectedExtras, extraOpeningBalances: extraOpenings
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
            case .emptyBank, .emptyName: errorText = "请选择或填写银行。"
            case .invalidCardNumber: errorText = "卡号格式不正确。"
            }
        } catch {
            errorText = "保存失败：\(error)"
        }
    }
}
