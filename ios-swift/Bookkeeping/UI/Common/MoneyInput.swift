import SwiftUI
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

    func value(_ currency: CurrencyCode) -> MoneyInput.Value {
        MoneyInput.parse(text, negative: isDebt, currency: currency)
    }

    /// 已经填过的初始余额
    static func existing(_ minor: Int64, currency: CurrencyCode) -> BalanceInput {
        BalanceInput(text: MoneyInput.editingText(minor, currency: currency), isDebt: minor < 0)
    }
}

/// 一个币种的初始余额（选填）：左边下拉选「余额 / 欠款」（和卡类型一样的下拉框），右边填金额。
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
            Picker("余额类型", selection: $input.isDebt) {
                Text("余额").tag(false)
                Text("欠款").tag(true)
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            TextField("初始余额（选填）", text: $input.text)
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
