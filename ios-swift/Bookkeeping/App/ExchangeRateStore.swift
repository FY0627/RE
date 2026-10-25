import Foundation
import Observation
import BKBackend
import BKModel

/// 主要币种与可选的联网汇率。
///
/// 默认不联网。用户在「我的」里打开「联网获取汇率」后，App 启动或回到前台时，
/// 距上次下载超过 6 小时才请求一次公开汇率；请求只含基准币种代码，不带任何账本数据，
/// 使用无缓存、无 Cookie 的临时会话。汇率只用于资产页净资产的换算显示，卡片和流水始终是原币种。
@MainActor
@Observable
final class ExchangeRateStore {
    nonisolated static let enabledKey = "fx.enabled"
    nonisolated static let primaryKey = "fx.primaryCurrency"
    private static let cacheKey = "fx.cache"
    private static let refreshInterval: TimeInterval = 6 * 3600

    private(set) var rates: ExchangeRates?
    private(set) var isUpdating = false
    private(set) var lastError: String?

    private let defaults = UserDefaults.standard

    init() {
        if let data = defaults.data(forKey: Self.cacheKey) {
            rates = try? JSONDecoder().decode(ExchangeRates.self, from: data)
        }
    }

    var enabled: Bool { defaults.bool(forKey: Self.enabledKey) }

    /// 开启时可用的汇率；关闭联网时返回 nil（不使用旧的缓存）
    var activeRates: ExchangeRates? { enabled ? rates : nil }

    func refreshIfNeeded(force: Bool = false) async {
        guard enabled, !isUpdating else { return }
        if !force, let rates, Date().timeIntervalSince(rates.fetchedAt) < Self.refreshInterval { return }
        isUpdating = true
        defer { isUpdating = false }
        do {
            let request = URLRequest(url: ExchangeRateFeed.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
            let session = URLSession(configuration: .ephemeral)
            defer { session.finishTasksAndInvalidate() }
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            let parsed = try ExchangeRateFeed.parse(data, fetchedAt: Date())
            rates = parsed
            lastError = nil
            if let encoded = try? JSONEncoder().encode(parsed) { defaults.set(encoded, forKey: Self.cacheKey) }
        } catch {
            lastError = (error as? URLError).map { _ in "网络不可用或请求失败" } ?? "汇率数据无法解析"
        }
    }
}
