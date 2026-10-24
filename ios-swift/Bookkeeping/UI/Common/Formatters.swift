import Foundation
import BKModel

/// 展示用格式化。金额全部走整数格式化（`MoneyFormat`），不经过 Double。
enum Fmt {
    static var calendar: Calendar { .current }

    static func money(_ minor: Int64, _ currency: CurrencyCode) -> String {
        MoneyFormat.string(Money(minorUnits: minor, currency: currency))
    }

    static func signed(_ record: LedgerRecord) -> String {
        MoneyFormat.signed(record.amountMinor, currency: record.currency, direction: record.direction)
    }

    private static func two(_ v: Int) -> String { v < 10 ? "0\(v)" : "\(v)" }

    static func time(_ date: Date) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return "\(two(c.hour ?? 0)):\(two(c.minute ?? 0))"
    }

    /// 「今天」「昨天」「10月24日」「2025年12月31日」
    static func day(_ date: Date, now: Date = Date()) -> String {
        let cal = calendar
        if cal.isDate(date, inSameDayAs: now) { return "今天" }
        if let yesterday = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(date, inSameDayAs: yesterday) { return "昨天" }
        let c = cal.dateComponents([.year, .month, .day, .weekday], from: date)
        let weekday = ["日", "一", "二", "三", "四", "五", "六"][((c.weekday ?? 1) - 1) % 7]
        if c.year == cal.component(.year, from: now) { return "\(c.month ?? 0)月\(c.day ?? 0)日 周\(weekday)" }
        return "\(c.year ?? 0)年\(c.month ?? 0)月\(c.day ?? 0)日"
    }

    static func dateTime(_ date: Date, now: Date = Date()) -> String {
        let label = day(date, now: now)
        return label.hasPrefix("今天") || label.hasPrefix("昨天") ? "\(label) \(time(date))" : "\(label.components(separatedBy: " ").first ?? label) \(time(date))"
    }

    static func monthTitle(year: Int, month: Int) -> String { "\(year)年\(month)月" }

    /// 列表里的交易时间：优先显示通知正文写明的时间，否则显示系统接收/处理时间。
    static func recordTime(_ r: LedgerRecord) -> String {
        if let t = r.transactionTime, t.hasTime || t.hasDate { return t.displayText }
        return time(r.effectiveAt)
    }
}

extension TransactionKind {
    var symbolName: String {
        switch self {
        case .purchase: "cart"
        case .income: "arrow.down.circle"
        case .salary: "briefcase"
        case .transferIn: "arrow.down.left.circle"
        case .transferOut: "arrow.up.right.circle"
        case .refund: "arrow.uturn.backward.circle"
        case .repayment: "checkmark.circle"
        case .interestCharge: "percent"
        case .fee: "doc.text"
        case .deposit: "tray.and.arrow.down"
        case .withdrawal: "banknote"
        case .interestIncome: "chart.line.uptrend.xyaxis"
        case .reversal: "arrow.uturn.left.square"
        case .other: "circle.dashed"
        }
    }
}

extension Notification.Name {
    /// 自动记账在 App 进程内写入数据后发出，界面据此刷新。
    static let ledgerDidChange = Notification.Name("bk.ledgerDidChange")
}
