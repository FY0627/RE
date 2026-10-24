import SwiftUI
import BKModel
import BKBackend

/// 添加银行卡：只要银行、后四位、卡类型和币种。不收集完整卡号、密码或邮箱凭据。
struct AddAccountView: View {
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
    @State private var saving = false
    @State private var errorText: String?
    @State private var created: Account?

    private static let customTag = "__custom"

    private var bankName: String {
        bankChoice == Self.customTag ? customBank.trimmingCharacters(in: .whitespaces) : (BankDirectory.profile(id: bankChoice)?.name ?? "")
    }

    private var isValid: Bool {
        !bankName.isEmpty && Account.isValidLast4(last4) && currency != nil
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
                } footer: {
                    Text("只保存后四位，用来匹配通知里的「尾号」。不要输入完整卡号。")
                }
                Section {
                    Picker("币种", selection: $currency) {
                        Text("请选择").tag(CurrencyCode?.none)
                        ForEach(CurrencyCode.common, id: \.self) { code in
                            Text("\(code.chineseName) \(code.rawValue)").tag(CurrencyCode?.some(code))
                        }
                    }
                } header: {
                    Text("记账币种")
                } footer: {
                    Text("通知没有写明币种时按这里的币种入账。App 不会根据手机地区自动假定欧元或人民币。")
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
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { Task { await save() } }.disabled(!isValid || saving)
                }
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
        let draft = AccountDraft(
            name: name, bankID: bankChoice == Self.customTag ? nil : bankChoice, bankName: bankName,
            last4: last4, cardType: cardType, currency: currency, paletteID: paletteID
        )
        do {
            created = try await store.addAccount(draft)
            errorText = nil
        } catch BackendError.invalidAccount(let reason) {
            switch reason {
            case .duplicateAccount: errorText = "已经添加过这张卡（同一银行、同一尾号、同一卡类型）。"
            case .invalidLast4: errorText = "后四位必须是 4 位数字。"
            case .emptyBank, .emptyName: errorText = "请选择或填写银行。"
            }
        } catch {
            errorText = "保存失败：\(error)"
        }
    }
}
