import SwiftUI

/// 底部玻璃导航（原型 `lib/widgets/liquid_dock.dart`）。
/// 指示块单独读取翻页位置，滑动时只有它重绘，标签图标保持不变。
struct LiquidDock: View {
    let selected: AppTab
    let pager: PagerState
    let onSelect: (AppTab) -> Void
    @Environment(\.colorScheme) private var scheme

    static let height: CGFloat = 52
    static let contentInset: CGFloat = 5
    static let indicatorInset: CGFloat = 3

    var body: some View {
        let palette = Theme(scheme: scheme)
        GeometryReader { proxy in
            let itemWidth = (proxy.size.width - Self.contentInset * 2) / CGFloat(AppTab.allCases.count)
            ZStack(alignment: .topLeading) {
                DockIndicator(pager: pager, itemWidth: itemWidth, color: palette.indicator)
                HStack(spacing: 0) {
                    ForEach(AppTab.allCases) { tab in
                        DockItem(tab: tab, selected: tab == selected, palette: palette) { onSelect(tab) }
                            .frame(width: itemWidth)
                    }
                }
                .padding(.horizontal, Self.contentInset)
                .padding(.vertical, 4)
            }
        }
        .frame(height: Self.height)
        .chromeBackground(Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("页面导航")
    }
}

private struct DockItem: View {
    let tab: AppTab
    let selected: Bool
    let palette: Theme
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: tab.symbol)
                    .font(.system(size: 17, weight: .regular))
                    .frame(height: 20)
                Text(tab.title).font(.system(size: 9))
            }
            .foregroundStyle(selected ? (palette.isDark ? Color.white : Color(hex: 0x141416)) : palette.muted)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// 选中胶囊：跟随翻页位置移动，经过两页之间时横向拉伸（原型：width × (1 + sin(πt)·0.72)）。
private struct DockIndicator: View {
    let pager: PagerState
    let itemWidth: CGFloat
    let color: Color

    var body: some View {
        let height = LiquidDock.height - LiquidDock.indicatorInset * 2
        let rest = max(height, itemWidth + (LiquidDock.contentInset - LiquidDock.indicatorInset) * 2)
        let maxIndex = CGFloat(AppTab.allCases.count - 1)
        let position = min(max(pager.position, 0), maxIndex)
        let fraction = position - position.rounded(.down)
        let width = rest * (1 + sin(fraction * .pi) * 0.72)
        let center = LiquidDock.contentInset + (position + 0.5) * itemWidth
        Capsule()
            .fill(color)
            .frame(width: width, height: height)
            .offset(x: center - width / 2, y: LiquidDock.indicatorInset)
            .allowsHitTesting(false)
    }
}
