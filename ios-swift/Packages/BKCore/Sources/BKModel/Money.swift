/// 币种代码（ISO 4217）。只保存代码本身，不从设备地区推断。
public struct CurrencyCode: Hashable, Sendable, Codable, RawRepresentable, Comparable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue.uppercased()
    }

    public init(_ code: String) {
        self.init(rawValue: code)
    }

    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }

    public static func < (lhs: CurrencyCode, rhs: CurrencyCode) -> Bool { lhs.rawValue < rhs.rawValue }

    /// 最小货币单位的小数位数。
    public var minorUnitExponent: Int { Self.exponents[rawValue] ?? 2 }

    private static let exponents: [String: Int] = [
        "JPY": 0, "KRW": 0, "VND": 0, "ISK": 0, "CLP": 0, "PYG": 0, "UGX": 0,
        "BHD": 3, "KWD": 3, "OMR": 3, "JOD": 3, "TND": 3, "IQD": 3, "LYD": 3,
    ]

    public static let cny = CurrencyCode("CNY")
    public static let eur = CurrencyCode("EUR")
    public static let usd = CurrencyCode("USD")
    public static let hkd = CurrencyCode("HKD")
    public static let gbp = CurrencyCode("GBP")
    public static let jpy = CurrencyCode("JPY")
    public static let chf = CurrencyCode("CHF")

    /// 添加账户时可选的常用币种（顺序只是展示顺序，不代表默认值）。
    public static let common: [CurrencyCode] = [
        .cny, .eur, .usd, .hkd, .gbp, .jpy, .chf,
        CurrencyCode("SGD"), CurrencyCode("AUD"), CurrencyCode("CAD"), CurrencyCode("MOP"),
        CurrencyCode("TWD"), CurrencyCode("KRW"), CurrencyCode("SEK"), CurrencyCode("NOK"),
        CurrencyCode("DKK"), CurrencyCode("PLN"), CurrencyCode("CZK"), CurrencyCode("HUF"),
    ]

    public var symbol: String {
        switch rawValue {
        case "CNY": "¥"
        case "EUR": "€"
        case "USD": "US$"
        case "HKD": "HK$"
        case "GBP": "£"
        case "JPY": "JP¥"
        case "MOP": "MOP$"
        case "TWD": "NT$"
        case "SGD": "S$"
        case "AUD": "A$"
        case "CAD": "C$"
        case "KRW": "₩"
        default: rawValue + " "
        }
    }

    public var chineseName: String {
        switch rawValue {
        case "CNY": "人民币"
        case "EUR": "欧元"
        case "USD": "美元"
        case "HKD": "港币"
        case "GBP": "英镑"
        case "JPY": "日元"
        case "CHF": "瑞士法郎"
        case "SGD": "新加坡元"
        case "AUD": "澳元"
        case "CAD": "加元"
        case "MOP": "澳门元"
        case "TWD": "新台币"
        case "KRW": "韩元"
        case "SEK": "瑞典克朗"
        case "NOK": "挪威克朗"
        case "DKK": "丹麦克朗"
        case "PLN": "波兰兹罗提"
        case "CZK": "捷克克朗"
        case "HUF": "匈牙利福林"
        default: rawValue
        }
    }
}

/// 金额：最小货币单位的整数 + 币种。账务运算全部用整数，不经过 Float/Double。
public struct Money: Hashable, Sendable, Codable {
    public var minorUnits: Int64
    public var currency: CurrencyCode

    public init(minorUnits: Int64, currency: CurrencyCode) {
        self.minorUnits = minorUnits
        self.currency = currency
    }

    /// 币种不同时返回 nil，调用方必须按币种分别汇总。
    public func adding(_ other: Money) -> Money? {
        guard other.currency == currency else { return nil }
        let (sum, overflow) = minorUnits.addingReportingOverflow(other.minorUnits)
        return overflow ? nil : Money(minorUnits: sum, currency: currency)
    }

    public var negated: Money { Money(minorUnits: -minorUnits, currency: currency) }
}

public enum MoneyFormat {
    /// 与地区设置无关的金额文本，例如 `1,234.56`。
    public static func plain(_ minorUnits: Int64, exponent: Int, grouping: Bool = true) -> String {
        let negative = minorUnits < 0
        let magnitude = minorUnits.magnitude
        var divisor: UInt64 = 1
        for _ in 0..<max(0, exponent) { divisor *= 10 }
        let integerPart = magnitude / divisor
        let fraction = magnitude % divisor
        var integerText = String(integerPart)
        if grouping, integerText.count > 3 {
            var grouped = ""
            for (offset, character) in integerText.enumerated() {
                if offset > 0, (integerText.count - offset) % 3 == 0 { grouped.append(",") }
                grouped.append(character)
            }
            integerText = grouped
        }
        var text = integerText
        if exponent > 0 {
            var fractionText = String(fraction)
            while fractionText.count < exponent { fractionText = "0" + fractionText }
            text += "." + fractionText
        }
        return negative ? "-" + text : text
    }

    public static func string(_ money: Money, grouping: Bool = true) -> String {
        let body = plain(money.minorUnits, exponent: money.currency.minorUnitExponent, grouping: grouping)
        if body.hasPrefix("-") { return "-" + money.currency.symbol + body.dropFirst() }
        return money.currency.symbol + body
    }

    /// 带方向符号：流入 `+`，流出 `-`。
    public static func signed(_ minorUnits: Int64, currency: CurrencyCode, direction: FlowDirection) -> String {
        let body = plain(minorUnits, exponent: currency.minorUnitExponent)
        return (direction == .inflow ? "+" : "-") + currency.symbol + body
    }
}
