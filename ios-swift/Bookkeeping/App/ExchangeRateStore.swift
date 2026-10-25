import Foundation
import Observation
import BKBackend
import BKModel

/// 主要币种与汇率。汇率只用于资产页净资产的换算显示，卡片和流水始终是原币种。
///
/// 汇率有两个来源，结果存在同一份本机缓存里：
/// - **快捷指令导入**（推荐，App 不联网）：自动化里先用「获取 URL 内容」下载，再交给 App 动作「导入汇率」；
/// - **App 联网获取**（默认关闭）：用户打开开关后，App 启动或回到前台时、距上次超过 6 小时才请求一次，
///   只含基准币种代码，使用无缓存、无 Cookie 的临时会话。
/// 快捷指令导入的汇率总是可用；App 自己下载的汇率只在开关打开时使用。
@MainActor
@Observable
final class ExchangeRateStore {
    enum Source: String {
        case shortcut
        case network

        var displayName: String {
            switch self {
            case .shortcut: "快捷指令导入"
            case .network: "App 联网获取"
            }
        }
    }

    nonisolated static let enabledKey = "fx.enabled"
    nonisolated static let primaryKey = "fx.primaryCurrency"
    nonisolated private static let cacheKey = "fx.cache"
    nonisolated private static let sourceKey = "fx.source"
    private static let refreshInterval: TimeInterval = 6 * 3600

    private(set) var rates: ExchangeRates?
    private(set) var source: Source?
    private(set) var isUpdating = false
    private(set) var lastError: String?

    init() {
        reload()
        // App 动作「导入汇率」在后台写入缓存后通知界面
        NotificationCenter.default.addObserver(forName: .exchangeRatesDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    private func reload() {
        let defaults = UserDefaults.standard
        rates = defaults.data(forKey: Self.cacheKey).flatMap { try? JSONDecoder().decode(ExchangeRates.self, from: $0) }
        source = defaults.string(forKey: Self.sourceKey).flatMap(Source.init(rawValue:)) ?? (rates == nil ? nil : .network)
    }

    /// 写入本机缓存。App 动作和 App 内联网共用，可以在任何线程调用。
    nonisolated static func save(_ rates: ExchangeRates, source: Source) {
        guard let encoded = try? JSONEncoder().encode(rates) else { return }
        UserDefaults.standard.set(encoded, forKey: cacheKey)
        UserDefaults.standard.set(source.rawValue, forKey: sourceKey)
    }

    /// 用于换算的汇率：快捷指令导入的总是可用；App 自己下载的只在开关打开时使用。
    func usableRates(networkEnabled: Bool) -> ExchangeRates? {
        guard let rates else { return nil }
        return source == .shortcut || networkEnabled ? rates : nil
    }

    func refreshIfNeeded(force: Bool = false) async {
        guard UserDefaults.standard.bool(forKey: Self.enabledKey), !isUpdating else { return }
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
            Self.save(parsed, source: .network)
            rates = parsed
            source = .network
            lastError = nil
        } catch {
            lastError = (error as? URLError).map { _ in "网络不可用或请求失败" } ?? "汇率数据无法解析"
        }
    }
}

extension Notification.Name {
    static let exchangeRatesDidChange = Notification.Name("bk.exchangeRatesDidChange")
}
