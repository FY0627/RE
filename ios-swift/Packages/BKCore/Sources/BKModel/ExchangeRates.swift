import Foundation

/// 汇率快照：1 个 `base` 等于多少其他币种。只用于资产页的换算显示，不参与记账；账本里的金额始终是原币种整数。
public struct ExchangeRates: Hashable, Sendable, Codable {
    public var base: CurrencyCode
    /// 币种代码 → 1 个 base 可兑换的数量
    public var rates: [String: Double]
    /// 数据源的更新时间
    public var updatedAt: Date
    /// 本机下载的时间
    public var fetchedAt: Date

    public init(base: CurrencyCode, rates: [String: Double], updatedAt: Date, fetchedAt: Date) {
        self.base = base
        self.rates = rates
        self.updatedAt = updatedAt
        self.fetchedAt = fetchedAt
    }

    public func rate(_ currency: CurrencyCode) -> Double? {
        if currency == base { return 1 }
        guard let value = rates[currency.rawValue], value > 0, value.isFinite else { return nil }
        return value
    }

    public func canConvert(_ from: CurrencyCode, to: CurrencyCode) -> Bool {
        from == to || (rate(from) != nil && rate(to) != nil)
    }

    /// 最小货币单位之间换算（按两种币种各自的小数位数），四舍五入到目标币种的最小单位；缺汇率时返回 nil。
    public func convert(_ minor: Int64, from: CurrencyCode, to: CurrencyCode) -> Int64? {
        if from == to { return minor }
        guard let fromRate = rate(from), let toRate = rate(to) else { return nil }
        let major = Double(minor) / pow(10, Double(from.minorUnitExponent))
        let converted = major / fromRate * toRate * pow(10, Double(to.minorUnitExponent))
        guard converted.isFinite, abs(converted) < 9e15 else { return nil }
        return Int64(converted.rounded())
    }
}
