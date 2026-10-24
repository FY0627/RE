import SwiftUI
import Observation

/// 单变量性能开关。每个开关只控制一件事，便于在真机上做 A/B 对照：
/// 一次只改一个开关，其余保持默认，录屏或看调试指标对比。
/// 标签栏、导航栏和按钮都是系统原生控件（液态玻璃由系统渲染），不在这里切换。
@MainActor
@Observable
final class PerfFlags {
    static let shared = PerfFlags()

    private let defaults = UserDefaults.standard

    /// 卡片阴影（堆叠时每张卡一份阴影）
    var cardShadows: Bool { didSet { defaults.set(cardShadows, forKey: "perf.cardShadows") } }
    /// 卡面先合成为一张位图（drawingGroup）再参与滚动和转场
    var rasterizeCards: Bool { didSet { defaults.set(rasterizeCards, forKey: "perf.rasterizeCards") } }
    /// 转场时被下一张卡遮住的部分用遮罩裁掉（原型的 rounded flight clip）
    var flightMask: Bool { didSet { defaults.set(flightMask, forKey: "perf.flightMask") } }
    /// 屏幕角落的帧率 / 内存调试指标
    var showMetrics: Bool { didSet { defaults.set(showMetrics, forKey: "perf.showMetrics") } }

    private init() {
        cardShadows = UserDefaults.standard.object(forKey: "perf.cardShadows") as? Bool ?? true
        rasterizeCards = UserDefaults.standard.object(forKey: "perf.rasterizeCards") as? Bool ?? false
        flightMask = UserDefaults.standard.object(forKey: "perf.flightMask") as? Bool ?? true
        showMetrics = UserDefaults.standard.object(forKey: "perf.showMetrics") as? Bool ?? false
    }

    func resetToDefaults() {
        cardShadows = true
        rasterizeCards = false
        flightMask = true
        showMetrics = false
    }

    /// 当前开关组合的简短描述，录屏对照时显示在调试指标里
    var summary: String {
        "shadow=\(cardShadows ? 1 : 0) raster=\(rasterizeCards ? 1 : 0) mask=\(flightMask ? 1 : 0)"
    }
}
