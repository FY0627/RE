import SwiftUI

/// 卡片详情转场的共享时序（原型 `lib/widgets/account_detail_motion.dart`）。
/// 进入 800ms，返回 620ms；所有元素都由同一个 0→1 的进度换算，返回时沿同一条函数反向播放。
enum DetailMotion {
    static let duration: Double = 0.8
    static let reverseDuration: Double = 0.62
    static let firstStageEnd: Double = 0.24
    static let secondStageEnd: Double = 0.70

    private static let travelCurve = CubicCurve(0.2, 0.85, 0.2, 1)
    private static let exitCurve = CubicCurve(0.4, 0.15, 0.7, 1)
    private static let easeInOutCubic = CubicCurve(0.645, 0.045, 0.355, 1)
    private static let easeOutCubic = CubicCurve(0.215, 0.61, 0.355, 1)

    /// 选中卡片移动（0 – 0.70）
    static func cardTravel(_ t: Double) -> Double { interval(t, 0, secondStageEnd, travelCurve) }
    /// 其余卡片离场（0 – 0.70）
    static func stackExit(_ t: Double) -> Double { interval(t, 0, secondStageEnd, exitCurve) }
    /// 顶部按钮出现（0.24 – 0.70）
    static func topButtons(_ t: Double) -> Double { interval(t, firstStageEnd, secondStageEnd, easeInOutCubic) }
    /// 资产页标题、净资产卡和「银行卡」标题行淡出（0 – 0.24）
    static func headerFade(_ t: Double) -> Double { interval(t, 0, firstStageEnd, easeOutCubic) }
    /// 资产页右上角「+」缩小消失（0 – 0.24），之后详情页的按钮在同一位置出现
    static func listButtonsExit(_ t: Double) -> Double { 1 - interval(t, 0, firstStageEnd, easeInOutCubic) }
    /// 详情内容进入（0.70 – 1）
    static func contentEntrance(_ t: Double) -> Double { interval(t, secondStageEnd, 1, easeOutCubic) }

    private static func interval(_ t: Double, _ begin: Double, _ end: Double, _ curve: CubicCurve) -> Double {
        let local = min(1, max(0, (t - begin) / (end - begin)))
        return curve.value(local)
    }
}

/// 三次贝塞尔缓动曲线（与 Flutter `Cubic` / CSS cubic-bezier 相同定义）。
struct CubicCurve {
    let x1: Double, y1: Double, x2: Double, y2: Double

    init(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) {
        self.x1 = x1
        self.y1 = y1
        self.x2 = x2
        self.y2 = y2
    }

    private func sample(_ a: Double, _ b: Double, _ m: Double) -> Double {
        3 * a * (1 - m) * (1 - m) * m + 3 * b * (1 - m) * m * m + m * m * m
    }

    func value(_ t: Double) -> Double {
        if t <= 0 { return 0 }
        if t >= 1 { return 1 }
        var low = 0.0, high = 1.0
        for _ in 0..<24 {
            let mid = (low + high) / 2
            if sample(x1, x2, mid) < t { low = mid } else { high = mid }
        }
        return sample(y1, y2, (low + high) / 2)
    }
}

/// 原型 `CenteredControlTransition`：圆形按钮等比缩放，胶囊横向为主。
struct CenteredControlScale: ViewModifier, Animatable {
    var progress: Double
    var circular: Bool
    var stage: (Double) -> Double

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let visible = stage(progress)
        let scaleX = circular ? 0.12 + 0.88 * visible : 0.1 + 0.9 * visible
        let scaleY = circular ? scaleX : 0.75 + 0.25 * visible
        content.scaleEffect(x: scaleX, y: scaleY).opacity(visible)
    }
}
