import SwiftUI
import UIKit

/// 页面顶部一行的磨砂背景：列表滚到这一行下面时出现，往下渐渐变淡。首页、统计页、「我的」用。
///
/// 不用系统的滚动边缘效果：系统的效果按这一行里的文字决定画在哪，首页搜索展开、标题淡出时它会突然消失。
/// 这里只看列表有没有滚到下面，搜索展开、收起都不变。
struct TopBarBackdrop: View {
    let visible: Bool

    var body: some View {
        Rectangle()
            .fill(.bar)
            .mask {
                LinearGradient(
                    stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.65), .init(color: .clear, location: 1)],
                    startPoint: .top, endPoint: .bottom
                )
            }
            // 往下多盖一点，渐变到透明；往上盖住状态栏
            .padding(.bottom, -18)
            .ignoresSafeArea(edges: .top)
            .opacity(visible ? 1 : 0)
            .animation(.easeOut(duration: 0.2), value: visible)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

extension View {
    /// 列表有没有滚到顶部那一行下面（给 `TopBarBackdrop` 用）；同时关掉系统的上边缘效果，免得画两层
    func trackingScrollUnderTopBar(_ scrolled: Binding<Bool>) -> some View {
        scrollEdgeEffectHidden(true, for: .top)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top > 1
            } action: { _, value in
                scrolled.wrappedValue = value
            }
    }
}

/// 页面顶部一行：左边大标题，右边一个玻璃胶囊，里面几个图标按钮。和首页、资产页的标题行一样高、一样的字号。
/// 统计页用它放「上个月 / 下个月」；「我的」没有按钮，只有标题。
struct TitleBar: UIViewRepresentable {
    struct Item {
        let symbol: String
        let label: String
        let action: () -> Void
    }

    let title: String
    let items: [Item]

    func makeUIView(context: Context) -> TitleBarView {
        TitleBarView(title: title, items: items.map { (symbol: $0.symbol, label: $0.label) })
    }

    func updateUIView(_ view: TitleBarView, context: Context) {
        view.actions = items.map(\.action)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: TitleBarView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 320, height: GlassControls.size)
    }
}

@MainActor
final class TitleBarView: UIView {
    /// 和按钮一一对应
    var actions: [() -> Void] = []

    private let titleLabel = UILabel()
    private let container = GlassControls.container()
    private let capsule = GlassControls.capsule(GlassControls.glass())
    private var buttons: [UIButton] = []

    init(title: String, items: [(symbol: String, label: String)]) {
        super.init(frame: .zero)
        let metrics = UIFontMetrics(forTextStyle: .largeTitle)
        titleLabel.font = metrics.scaledFont(for: UIFont.systemFont(ofSize: 34, weight: .bold))
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.text = title
        titleLabel.textColor = .label
        titleLabel.accessibilityTraits = .header
        addSubview(titleLabel)

        container.frame = bounds
        container.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.isHidden = items.isEmpty
        addSubview(container)
        container.contentView.addSubview(capsule)
        for (index, item) in items.enumerated() {
            let button = GlassControls.iconButton(item.symbol, label: item.label)
            button.addAction(UIAction { [weak self] _ in
                guard let self, self.actions.indices.contains(index) else { return }
                self.actions[index]()
            }, for: .primaryActionTriggered)
            capsule.contentView.addSubview(button)
            buttons.append(button)
        }
        accessibilityElements = [titleLabel as UIView] + buttons.map { $0 as UIView }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = GlassControls.size
        let width = size * CGFloat(buttons.count)
        if !buttons.isEmpty {
            GlassControls.place(capsule, CGRect(x: bounds.width - width, y: 0, width: width, height: size))
        }
        for (index, button) in buttons.enumerated() {
            button.frame = CGRect(x: CGFloat(index) * size, y: 0, width: size, height: size)
        }
        let trailing = buttons.isEmpty ? 0 : width + GlassControls.gap
        titleLabel.frame = CGRect(x: 4, y: 0, width: max(0, bounds.width - trailing - 4), height: size)
    }

    /// 只有玻璃接收触摸，标题和空白处不挡住下面的列表
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let hit = super.hitTest(point, with: event) else { return nil }
        return hit.isDescendant(of: capsule) ? hit : nil
    }
}
