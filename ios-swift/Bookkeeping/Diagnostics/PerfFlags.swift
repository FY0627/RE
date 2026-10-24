import SwiftUI
import Observation

/// 单变量性能开关。每个开关只控制一件事，便于在真机上做 A/B 对照：
/// 一次只改一个开关，其余保持默认，录屏或看调试指标对比。
@MainActor
@Observable
final class PerfFlags {
    enum Chrome: String, CaseIterable, Identifiable {
        /// iOS 26+ 系统 Liquid Glass（实时折射与模糊）
        case glass
        /// 系统材质模糊（ultraThinMaterial）
        case material
        /// 半透明纯色，无实时模糊
        case solid

        var id: String { rawValue }
        var title: String {
            switch self {
            case .glass: "系统液态玻璃"
            case .material: "材质模糊"
            case .solid: "纯色（无模糊）"
            }
        }
    }

    static let shared = PerfFlags()

    private let defaults = UserDefaults.standard

    /// 底部导航、加号、详情页按钮的背景
    var chrome: Chrome { didSet { defaults.set(chrome.rawValue, forKey: "perf.chrome") } }
    /// 卡片阴影（堆叠时每张卡一份阴影）
    var cardShadows: Bool { didSet { defaults.set(cardShadows, forKey: "perf.cardShadows") } }
    /// 卡面先合成为一张位图（drawingGroup）再参与滚动和转场
    var rasterizeCards: Bool { didSet { defaults.set(rasterizeCards, forKey: "perf.rasterizeCards") } }
    /// 转场时被下一张卡遮住的部分用遮罩裁掉（原型的 rounded flight clip）
    var flightMask: Bool { didSet { defaults.set(flightMask, forKey: "perf.flightMask") } }
    /// 加号水滴的高光描边
    var dropletHighlight: Bool { didSet { defaults.set(dropletHighlight, forKey: "perf.dropletHighlight") } }
    /// 屏幕角落的帧率 / 内存调试指标
    var showMetrics: Bool { didSet { defaults.set(showMetrics, forKey: "perf.showMetrics") } }

    private init() {
        chrome = Chrome(rawValue: UserDefaults.standard.string(forKey: "perf.chrome") ?? "") ?? .glass
        cardShadows = UserDefaults.standard.object(forKey: "perf.cardShadows") as? Bool ?? true
        rasterizeCards = UserDefaults.standard.object(forKey: "perf.rasterizeCards") as? Bool ?? false
        flightMask = UserDefaults.standard.object(forKey: "perf.flightMask") as? Bool ?? true
        dropletHighlight = UserDefaults.standard.object(forKey: "perf.dropletHighlight") as? Bool ?? true
        showMetrics = UserDefaults.standard.object(forKey: "perf.showMetrics") as? Bool ?? false
    }

    func resetToDefaults() {
        chrome = .glass
        cardShadows = true
        rasterizeCards = false
        flightMask = true
        dropletHighlight = true
        showMetrics = false
    }

    /// 当前开关组合的简短描述，录屏对照时显示在调试指标里
    var summary: String {
        "UI=\(chrome.rawValue) shadow=\(cardShadows ? 1 : 0) raster=\(rasterizeCards ? 1 : 0) mask=\(flightMask ? 1 : 0) hl=\(dropletHighlight ? 1 : 0)"
    }
}

/// 背景材质按开关切换。
struct ChromeBackground<S: Shape>: ViewModifier {
    let shape: S
    var tint: Color? = nil
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let flags = PerfFlags.shared
        let palette = Theme(scheme: scheme)
        switch flags.chrome {
        case .glass:
            content.glassEffect(tint.map { Glass.regular.tint($0) } ?? Glass.regular, in: shape)
        case .material:
            content
                .background(.ultraThinMaterial, in: shape)
                .background(palette.glassTint, in: shape)
                .overlay(shape.stroke(Color.white.opacity(palette.isDark ? 0.18 : 0.4), lineWidth: 0.5))
                .shadow(color: .black.opacity(palette.isDark ? 0.3 : 0.07), radius: 7, y: 3)
        case .solid:
            content
                .background(shape.fill(palette.isDark ? Color(hex: 0x1C1C1E, opacity: 0.94) : Color(hex: 0xFFFFFF, opacity: 0.94)))
                .overlay(shape.stroke(palette.line, lineWidth: 0.5))
        }
    }
}

extension View {
    func chromeBackground<S: Shape>(_ shape: S, tint: Color? = nil) -> some View {
        modifier(ChromeBackground(shape: shape, tint: tint))
    }
}
