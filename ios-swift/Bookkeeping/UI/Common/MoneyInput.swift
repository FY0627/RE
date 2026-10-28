import SwiftUI
import UIKit
import BKBackend
import BKModel

/// 用户输入的金额 → 最小货币单位。和解析银行通知用同一套整数规则，
/// 接受 `1234.56`、`1,234.56`、`1234,56`（欧洲键盘的小数逗号），不经过浮点数。
enum MoneyInput {
    enum Value: Equatable {
        case empty
        case valid(Int64)
        case invalid
    }

    static func parse(_ text: String, negative: Bool, currency: CurrencyCode?) -> Value {
        let trimmed = text.filter { !$0.isWhitespace }
        if trimmed.isEmpty { return .empty }
        let exponent = currency?.minorUnitExponent ?? 2
        switch AmountParser.minorUnits(trimmed, exponent: exponent) {
        case .success(let minor): return .valid(negative ? -minor : minor)
        case .failure: return .invalid
        }
    }

    /// 编辑已有金额时的初始文本（不带千位分隔和符号）
    static func editingText(_ minor: Int64, currency: CurrencyCode) -> String {
        MoneyFormat.plain(minor == .min ? 0 : abs(minor), exponent: currency.minorUnitExponent, grouping: false)
    }
}

/// 一个币种的初始余额：余额还是欠款 + 填的金额
struct BalanceInput: Hashable {
    var text = ""
    var isDebt = false
    /// 已经填过的初始余额（卡片信息里编辑时）：输入框空着，原来的金额灰色显示在框里；不填就保持原来的金额
    var existing: Int64?

    func value(_ currency: CurrencyCode) -> MoneyInput.Value {
        if let existing, text.allSatisfy(\.isWhitespace) {
            let magnitude = existing == .min ? Int64.max : abs(existing)
            return .valid(isDebt ? -magnitude : magnitude)
        }
        return MoneyInput.parse(text, negative: isDebt, currency: currency)
    }

    /// 输入框里灰色的提示：原来的金额，没填过时提示选填
    func placeholder(_ currency: CurrencyCode) -> String {
        guard let existing else { return "初始余额（选填）" }
        return MoneyFormat.plain(existing == .min ? 0 : abs(existing), exponent: currency.minorUnitExponent)
    }

    static func existing(_ minor: Int64) -> BalanceInput {
        BalanceInput(isDebt: minor < 0, existing: minor)
    }
}

/// 一个币种的初始余额（选填）：左边下拉选「余额 / 欠款」，右边填金额。
/// 放在选好的币种下面，添加银行卡和卡片信息共用。
struct OpeningBalanceRow: View {
    let currency: CurrencyCode
    /// 多币种的卡在最左边写币种
    var label: String?
    @Binding var input: BalanceInput

    var body: some View {
        HStack(spacing: 8) {
            if let label {
                Text(label).lineLimit(1)
            }
            // 只是文字加箭头，不用系统下拉框的按钮外框（那样这一行会变高）
            Menu {
                Picker("余额类型", selection: $input.isDebt) {
                    Text("余额").tag(false)
                    Text("欠款").tag(true)
                }
            } label: {
                HStack(spacing: 3) {
                    Text(input.isDebt ? "欠款" : "余额")
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.secondary)
                }
                .foregroundStyle(Color.primary)
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .fixedSize()
            .accessibilityLabel(input.isDebt ? "欠款" : "余额")
            TextField(input.placeholder(currency), text: $input.text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .font(.body.monospacedDigit())
                .accessibilityLabel("\(currency.chineseName)初始余额")
        }
        if case .invalid = input.value(currency) {
            Text("金额格式不对，例如 1234.56").font(.footnote).foregroundStyle(.red)
        }
    }
}

extension View {
    /// 数字键盘没有收起键：键盘上方右边放一个收起按钮，往下拖动表单也会收起
    func keyboardDismissible() -> some View {
        scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("收起键盘", systemImage: "keyboard.chevron.compact.down") {
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    }
                }
            }
    }
}
