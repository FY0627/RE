import SwiftUI
import UIKit
import BKModel
import BKBackend

/// 卡片信息：银行、卡类型、币种、完整卡号（选填，默认遮住）。可以改账户名称、卡号、多币种账户的其他币种，也可以隐藏这张卡。
/// 银行、尾号、卡类型、主币种决定自动记账的匹配，这里只显示不修改。
struct CardInfoView: View {
    let accountID: String
    /// 隐藏这张卡：由详情页关闭详情后归档
    let onHide: () -> Void

    @Environment(LedgerStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var editing = false
    @State private var name = ""
    @State private var number = ""
    @State private var multiCurrency = false
    @State private var extras: [CurrencyCode] = []
    @State private var revealed = false
    @State private var copied = false
    @State private var saving = false
    @State private var confirmHide = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            if let account = store.account(id: accountID) {
                form(account)
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func form(_ account: Account) -> some View {
        Form {
            Section {
                if editing {
                    TextField("账户名称", text: $name)
                } else {
                    LabeledContent("账户名称", value: account.name)
                }
                LabeledContent("银行", value: account.bankName)
                LabeledContent("卡类型", value: account.cardType.displayName)
                LabeledContent(account.isMultiCurrency ? "主币种" : "币种", value: "\(account.currency.chineseName) \(account.currency.rawValue)")
                if account.isMultiCurrency, !editing {
                    LabeledContent("其他币种", value: account.extraCurrencies.map(\.chineseName).joined(separator: "、"))
                }
                LabeledContent("添加时间", value: Fmt.dateTime(account.createdAt))
            }

            Section {
                if editing {
                    TextField("完整卡号（选填）", text: $number)
                        .keyboardType(.numberPad)
                        .font(.body.monospacedDigit())
                        .onChange(of: number) { _, value in
                            let digits = String(value.filter { $0.isASCII && $0.isNumber }.prefix(19))
                            if digits != value { number = digits }
                        }
                } else if let full = account.cardNumber {
                    numberRow(full)
                    Button(copied ? "已复制" : "复制卡号", systemImage: copied ? "checkmark" : "doc.on.doc") {
                        UIPasteboard.general.string = full
                        copied = true
                    }
                } else {
                    LabeledContent("卡号", value: "尾号 \(account.last4)")
                }
            } header: {
                Text("卡号")
            }

            if editing {
                Section {
                    Toggle("多币种账户", isOn: $multiCurrency)
                    if multiCurrency {
                        ExtraCurrencyList(primary: account.currency, selection: $extras)
                    }
                } header: {
                    Text("币种")
                }
            }

            if let errorText {
                Section { Text(errorText).foregroundStyle(.red) }
            }

            if !editing {
                Section {
                    Button("隐藏这张卡", systemImage: "eye.slash", role: .destructive) { confirmHide = true }
                }
            }
        }
        .navigationTitle(account.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if editing {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", systemImage: "xmark") {
                        editing = false
                        errorText = nil
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", systemImage: "checkmark") { Task { await save(account) } }
                        .disabled(saving)
                }
            } else {
                ToolbarItem(placement: .cancellationAction) {
                    Button("编辑") {
                        name = account.name
                        number = account.cardNumber ?? ""
                        multiCurrency = account.isMultiCurrency
                        extras = account.extraCurrencies
                        errorText = nil
                        editing = true
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成", systemImage: "checkmark") { dismiss() }
                }
            }
        }
        .confirmationDialog("隐藏这张卡？", isPresented: $confirmHide, titleVisibility: .visible) {
            Button("隐藏", role: .destructive) {
                dismiss()
                onHide()
            }
        } message: {
            Text("已有流水会保留。")
        }
    }

    /// 默认只露出尾号；点眼睛显示完整卡号（每 4 位一组）。
    private func numberRow(_ full: String) -> some View {
        HStack {
            Text(revealed ? Self.grouped(full) : Self.masked(full))
                .font(.body.monospacedDigit())
                .textSelection(.enabled)
            Spacer()
            Button {
                revealed.toggle()
            } label: {
                Image(systemName: revealed ? "eye.slash" : "eye").foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(revealed ? "遮住卡号" : "显示完整卡号")
        }
    }

    static func grouped(_ digits: String) -> String {
        var result = ""
        for (index, char) in digits.enumerated() {
            if index > 0, index % 4 == 0 { result.append(" ") }
            result.append(char)
        }
        return result
    }

    static func masked(_ digits: String) -> String {
        grouped(String(repeating: "•", count: max(0, digits.count - 4)) + digits.suffix(4))
    }

    private func save(_ account: Account) async {
        saving = true
        defer { saving = false }
        do {
            try await store.updateCardInfo(accountID: account.id, name: name, cardNumber: number, extraCurrencies: multiCurrency ? extras : [])
            errorText = nil
            revealed = false
            editing = false
        } catch BackendError.invalidAccount(.invalidCardNumber) {
            errorText = "卡号必须是 12–19 位数字，末四位是 \(account.last4)。"
        } catch {
            errorText = "保存失败：\(error)"
        }
    }
}
