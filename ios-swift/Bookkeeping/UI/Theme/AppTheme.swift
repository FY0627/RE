import SwiftUI

/// 颜色沿用 prototype 分支 `lib/theme/app_theme.dart`。
enum AppTheme {
    static let lightBg = Color(hex: 0xF2F1F6)
    static let darkBg = Color(hex: 0x000000)
    static let lightInk = Color(hex: 0x171719)
    static let darkInk = Color(hex: 0xF5F5F7)
    static let lightMuted = Color(hex: 0x85858A)
    static let darkMuted = Color(hex: 0x818187)
    static let lightSurface = Color(hex: 0xF5F5F7)
    static let darkSurface = Color(hex: 0x1C1C1E)
    static let lightLine = Color(hex: 0xECECEE)
    static let darkLine = Color(hex: 0x272729)
    static let lightIndicator = Color.black.opacity(0.08)
    static let darkIndicator = Color.white.opacity(0.16)
    static let income = Color(hex: 0x34C759)
    static let debt = Color(hex: 0xE54D2E)
}

/// 根据当前配色取值的便捷集合。
struct Theme {
    let scheme: ColorScheme

    var isDark: Bool { scheme == .dark }
    var bg: Color { isDark ? AppTheme.darkBg : AppTheme.lightBg }
    var ink: Color { isDark ? AppTheme.darkInk : AppTheme.lightInk }
    var muted: Color { isDark ? AppTheme.darkMuted : AppTheme.lightMuted }
    var surface: Color { isDark ? AppTheme.darkSurface : AppTheme.lightSurface }
    /// 日间卡片底色比背景更白一层，保持原型的层级
    var card: Color { isDark ? AppTheme.darkSurface : Color.white }
    var line: Color { isDark ? Color(hex: 0x2C2C2E) : AppTheme.lightLine }
    var indicator: Color { isDark ? AppTheme.darkIndicator : AppTheme.lightIndicator }
    var glassTint: Color { Color.white.opacity(0.15) }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

/// 卡面配色：取自原型卡包的渐变与文字颜色。
struct CardPalette: Identifiable, Hashable {
    let id: String
    let name: String
    let colors: [UInt32]
    let text: UInt32
    let subtext: UInt32

    var gradient: LinearGradient {
        LinearGradient(colors: colors.map { Color(hex: $0) }, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    var textColor: Color { Color(hex: text) }
    var subtextColor: Color { Color(hex: subtext) }

    static let all: [CardPalette] = [
        CardPalette(id: "autumn-gold", name: "秋日金", colors: [0xFBE49D, 0xF6C869, 0xE5A83B], text: 0x6A4706, subtext: 0x987227),
        CardPalette(id: "jade", name: "翡翠绿", colors: [0x07C160, 0x049C4C], text: 0xFFFFFF, subtext: 0xE2F8EB),
        CardPalette(id: "ocean", name: "海蓝", colors: [0x1677FF, 0x0754CB], text: 0xFFFFFF, subtext: 0xD3E7FF),
        CardPalette(id: "midnight", name: "曜石黑", colors: [0x262629, 0x171719, 0x0F0F11], text: 0xFFFFFF, subtext: 0xA5A5AB),
        CardPalette(id: "lime", name: "青柠", colors: [0x9FE870, 0x86D654], text: 0x163300, subtext: 0x2E5E0B),
        CardPalette(id: "forest", name: "森绿", colors: [0x009944, 0x007A33], text: 0xFFFFFF, subtext: 0xDCFCE7),
        CardPalette(id: "lagoon", name: "湖光", colors: [0x0093E9, 0x80D0C7], text: 0xFFFFFF, subtext: 0xE0F7FA),
        CardPalette(id: "graphite-gold", name: "石墨金", colors: [0x2B2B30, 0x18181A], text: 0xF2E2C4, subtext: 0x9E9585),
        CardPalette(id: "violet", name: "紫罗兰", colors: [0x660874, 0x3B2F7E], text: 0xFFFFFF, subtext: 0xE9D8FD),
        CardPalette(id: "aurora", name: "极光", colors: [0x38BDF8, 0x6366F1, 0xF472B6], text: 0xFFFFFF, subtext: 0xF0F9FF),
        CardPalette(id: "crimson", name: "绯红", colors: [0xD0263A, 0x8E0C22], text: 0xFFFFFF, subtext: 0xFFE4E6),
        CardPalette(id: "sunset", name: "落日", colors: [0xFF8A4C, 0xE5484D], text: 0xFFFFFF, subtext: 0xFFE8DD),
    ]

    static func named(_ id: String) -> CardPalette { all.first { $0.id == id } ?? all[2] }
}

/// 尺寸沿用 `lib/theme/app_layout.dart`：参考卡宽 295，堆叠卡高 186，详情卡高 196，露出 52。
enum AppLayout {
    static let cardInset: CGFloat = 16
    static let referenceCardWidth: CGFloat = 327 - 16 * 2
    static let stackedAspect: CGFloat = referenceCardWidth / 186
    static let detailAspect: CGFloat = referenceCardWidth / 196
    static let detailTop: CGFloat = 54

    static func cardWidth(_ viewport: CGFloat) -> CGFloat { max(1, viewport - cardInset * 2) }
    static func stackedHeight(_ viewport: CGFloat) -> CGFloat { cardWidth(viewport) / stackedAspect }
    static func detailHeight(_ viewport: CGFloat) -> CGFloat { cardWidth(viewport) / detailAspect }
    static func peek(_ viewport: CGFloat) -> CGFloat { 52 * cardWidth(viewport) / referenceCardWidth }
}
