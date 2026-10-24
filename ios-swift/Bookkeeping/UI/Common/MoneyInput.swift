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

/// 余额 / 欠款 + 金额输入框。添加银行卡和修改初始余额共用。
struct OpeningBalanceFields: View {
    @Binding var text: String
    @Binding var isDebt: Bool
    let currency: CurrencyCode?

    var body: some View {
        Picker("余额类型", selection: $isDebt) {
            Text("余额").tag(false)
            Text("欠款").tag(true)
        }
        .pickerStyle(.segmented)
        HStack {
            Text(isDebt ? "欠款" : "余额")
            TextField(currency.map { "\($0.symbol)0.00" } ?? "0.00", text: $text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .font(.body.monospacedDigit())
        }
        if case .invalid = MoneyInput.parse(text, negative: isDebt, currency: currency) {
            Text("金额格式不对，例如 1234.56").font(.footnote).foregroundStyle(.red)
        }
    }
}
