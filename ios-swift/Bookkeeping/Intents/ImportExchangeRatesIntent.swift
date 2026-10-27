import AppIntents
import Foundation
import BKBackend
import BKModel

/// 快捷指令自动化调用：把「获取 URL 内容」下载的汇率数据导入 App，App 自己不联网。
///
/// 自动化示例：触发条件「打开日常记账时」或「每天 8:00」→「获取 URL 内容」（汇率地址）→「导入汇率」。
/// 和「记录银行动账通知」一样完全在后台执行，不打开 App、不弹出交互。
struct ImportExchangeRatesIntent: AppIntent {
    static let title: LocalizedStringResource = "导入汇率"
    static let description = IntentDescription(
        "把「获取 URL 内容」下载的汇率数据导入日常记账，资产页按主要币种换算净资产。App 自己不联网。",
        categoryName: "汇率",
        searchKeywords: ["汇率", "货币", "换算", "外币"]
    )
    static let supportedModes: IntentModes = .background
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    static let isDiscoverable = true

    @Parameter(
        title: "汇率数据",
        description: "选择上一步「获取 URL 内容」的结果（URL 的内容）。",
        inputConnectionBehavior: .connectToPreviousIntentResult
    )
    var content: String?

    static var parameterSummary: some ParameterSummary {
        Summary("导入\(\.$content)")
    }

    init() {}

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let content, !content.isEmpty else { throw ImportFailure.empty }
        let rates: ExchangeRates
        do {
            rates = try ExchangeRateFeed.parse(Data(content.utf8), fetchedAt: Date())
        } catch {
            throw ImportFailure.unreadable
        }
        ExchangeRateStore.save(rates)
        // 每天的完整汇率表都留着：外币交易按交易当天的汇率估算扣款。账本暂时打不开（开机后没解锁过）时只更新最新汇率
        if let backend = try? AppServices.shared.backend() {
            _ = try? await backend.saveExchangeRates(rates)
        }
        await MainActor.run {
            NotificationCenter.default.post(name: .exchangeRatesDidChange, object: nil)
            // 外币交易的估算扣款可能变了：余额重新推算
            NotificationCenter.default.post(name: .ledgerDidChange, object: nil)
        }
        AppServices.logger.info("exchange rates imported count=\(rates.rates.count)")
        return .result(value: "已导入 \(rates.rates.count) 个币种的汇率")
    }
}

enum ImportFailure: Error, CustomLocalizedStringResourceConvertible {
    case empty
    case unreadable

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .empty: "没有收到汇率数据。请在「汇率数据」里选择「获取 URL 内容」的结果。"
        case .unreadable: "无法识别汇率数据。请确认「获取 URL 内容」的地址是 open.er-api.com 的汇率地址。"
        }
    }
}
