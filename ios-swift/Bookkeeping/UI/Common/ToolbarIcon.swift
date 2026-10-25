import SwiftUI

/// 与系统导航栏按钮同尺寸的图标：44pt 点按区域，17pt 图标。外面套 `.glassEffect(.regular.interactive(), in: Circle())`。
struct ToolbarIcon: View {
    let symbol: String

    init(_ symbol: String) {
        self.symbol = symbol
    }

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 17, weight: .medium))
            // 用 Color.primary 而不是层级样式 .primary：放在 Menu 里时层级样式会跟随强调色变成蓝色
            .foregroundStyle(Color.primary)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }
}
