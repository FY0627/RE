import Foundation
import BKBackend
import BKModel

/// CI 截图模式（`ios-swift/ci/screenshots.sh`），只在 Debug 构建中可用。
///
/// 启动参数：
/// - `-BKScreenshot YES`：使用独立的临时账本，每次启动清空并写入演示数据
/// - `-BKScreenshotTab home|assets|stats|profile`：启动后停在指定页面
/// - `-BKScreenshotSheet pending`：启动后打开待处理
/// - `-BKScreenshotToken <任意字符串>`：界面就绪后写入 `tmp/bk-screenshot-ready`，脚本据此判断何时截图
///
/// 演示数据全部是虚构的脱敏样例，与解析测试使用同样的通知写法。
enum ScreenshotMode {
    #if DEBUG
    static let isActive = UserDefaults.standard.bool(forKey: "BKScreenshot")
    #else
    static let isActive = false
    #endif

    static var tab: AppTab? {
        guard isActive else { return nil }
        switch UserDefaults.standard.string(forKey: "BKScreenshotTab") {
        case "home": return .home
        case "assets": return .assets
        case "stats": return .stats
        case "profile": return .profile
        default: return nil
        }
    }

    static var opensPending: Bool {
        isActive && UserDefaults.standard.string(forKey: "BKScreenshotSheet") == "pending"
    }

    static func markReady() {
        guard isActive, let token = UserDefaults.standard.string(forKey: "BKScreenshotToken") else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bk-screenshot-ready")
        try? token.write(to: url, atomically: true, encoding: .utf8)
    }

    /// 写入演示账户与通知。日期都落在本月（月初几天除外），统计页才有内容。
    static func seed(_ backend: LedgerBackend) async {
        #if DEBUG
        guard isActive else { return }
        let accounts = [
            AccountDraft(name: "", bankID: "cmb", bankName: "招商银行", last4: "0427", cardType: .debit, currency: .cny, paletteID: "graphite-gold"),
            AccountDraft(name: "", bankID: "boc", bankName: "中国银行", last4: "8810", cardType: .credit, currency: .cny, paletteID: "autumn-gold", openingBalanceMinor: -320_000),
            AccountDraft(name: "", bankID: "icbc", bankName: "工商银行", last4: "6621", cardType: .debit, currency: .cny, paletteID: "crimson"),
        ]
        // {T} 替换为「M月d日HH:mm」
        let messages: [(daysAgo: Int, hour: Int, minute: Int, sender: String?, text: String)] = [
            (9, 9, 30, "95555", "您尾号0427账户{T}收入人民币12,500.00元，摘要：代发工资，余额13,734.56元【招商银行】"),
            (7, 12, 18, "95588", "您账户6621于{T}快捷支付支出人民币56.80元，摘要：美团外卖，余额2,003.20元【工商银行】"),
            (5, 21, 5, "95566", "您尾号8810的信用卡{T}消费1,280.00元。【中国银行】"),
            (3, 10, 1, "95555", "张三于{T}向您尾号0427的账户转账500.00元，余额14,234.56元。【招商银行】"),
            (2, 19, 42, "95588", "您账户6621于{T}快捷支付支出人民币128.00元，摘要：滴滴出行，余额1,875.20元【工商银行】"),
            (1, 14, 30, "95555", "【招商银行】您尾号0427的储蓄卡于{T}在星巴克咖啡消费人民币38.00元，余额14,196.56元。"),
            (1, 16, 12, "95566", "您尾号8810的信用卡收到退款人民币99.00元，商户：京东商城。【中国银行】"),
            // 没有尾号 9932 的账户：进入待处理
            (1, 8, 15, "95555", "【招商银行】您尾号9932的储蓄卡于{T}在全家便利店消费人民币18.50元，余额326.40元。"),
        ]
        do {
            for draft in accounts { _ = try await backend.addAccount(draft) }
            for message in messages {
                let (stamp, date) = timestamp(daysAgo: message.daysAgo, hour: message.hour, minute: message.minute)
                let text = message.text.replacingOccurrences(of: "{T}", with: stamp)
                _ = try await backend.ingest(IngestRequest(text: text, source: .sms, sender: message.sender, receivedAt: date))
            }
        } catch {
            AppServices.logger.error("screenshot seed failed: \(String(describing: error), privacy: .public)")
        }
        #endif
    }

    private static func timestamp(daysAgo: Int, hour: Int, minute: Int) -> (String, Date) {
        let calendar = Calendar.current
        let now = Date()
        let monthStart = calendar.dateInterval(of: .month, for: now)?.start ?? now
        var day = calendar.date(byAdding: .day, value: -daysAgo, to: calendar.startOfDay(for: now)) ?? now
        if day < monthStart { day = monthStart }
        var date = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? now
        if date > now { date = calendar.date(byAdding: .day, value: -1, to: date) ?? now }
        let c = calendar.dateComponents([.month, .day, .hour, .minute], from: date)
        return (String(format: "%d月%d日%02d:%02d", c.month ?? 1, c.day ?? 1, c.hour ?? 0, c.minute ?? 0), date)
    }
}
