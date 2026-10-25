import Foundation
import BKModel

/// 公开汇率数据源（ExchangeRate-API 的免密钥接口，每日更新，覆盖 160 多个币种）。
/// 只在用户开启「联网获取汇率」时由 App 下载；请求里只有基准币种代码，不带任何账本数据。
/// 这里只负责地址和解析，网络请求在 App 里发起。
public enum ExchangeRateFeed {
    public static let url = URL(string: "https://open.er-api.com/v6/latest/USD")!
    public static let attribution = "汇率来自 ExchangeRate-API（open.er-api.com）"

    public enum ParseError: Error, Equatable {
        case invalidResponse
        case providerError(String)
    }

    private struct Response: Decodable {
        let result: String
        let base_code: String?
        let time_last_update_unix: Double?
        let rates: [String: Double]?
        let error_type: String?
    }

    public static func parse(_ data: Data, fetchedAt: Date) throws -> ExchangeRates {
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else { throw ParseError.invalidResponse }
        guard response.result == "success" else { throw ParseError.providerError(response.error_type ?? response.result) }
        guard let base = response.base_code, let rates = response.rates, !rates.isEmpty else { throw ParseError.invalidResponse }
        let valid = rates.filter { $0.value > 0 && $0.value.isFinite }
        let updatedAt = response.time_last_update_unix.map { Date(timeIntervalSince1970: $0) } ?? fetchedAt
        return ExchangeRates(base: CurrencyCode(base), rates: valid, updatedAt: updatedAt, fetchedAt: fetchedAt)
    }
}
