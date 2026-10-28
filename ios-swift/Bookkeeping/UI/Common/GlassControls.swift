import UIKit

/// UIKit 液态玻璃按钮的共用部分：资产页（`WalletTopBar`）和首页（`HomeTopBarView`）顶部那一行。
///
/// 同一个玻璃容器（`UIGlassContainerEffect`）里的玻璃重叠或相距不到 `mergeSpacing` 时画成一整块，分开时像水滴一样拉开。
/// 停下来时相邻的玻璃隔开 `gap`，比 `mergeSpacing` 大：停在融合距离以内时，两块玻璃之间会连着一道带尖角的细颈。
/// 位置和大小用 UIKit 的弹簧动画，交给 Core Animation，由系统渲染进程播放，主线程忙也不掉帧。
@MainActor
enum GlassControls {
    /// 和系统导航栏按钮一样：44pt 高
    static let size: CGFloat = 44
    static let mergeSpacing: CGFloat = 8
    static let gap: CGFloat = 12

    static func container() -> UIVisualEffectView {
        let effect = UIGlassContainerEffect()
        effect.spacing = mergeSpacing
        return UIVisualEffectView(effect: effect)
    }

    static func glass() -> UIGlassEffect {
        let effect = UIGlassEffect()
        effect.isInteractive = true
        return effect
    }

    /// 胶囊形状的一块玻璃；`effect` 为 nil 时先不显示，之后设成玻璃时系统播放「凝结」动画
    static func capsule(_ effect: UIVisualEffect?) -> UIVisualEffectView {
        let view = UIVisualEffectView(effect: effect)
        view.cornerConfiguration = .capsule()
        return view
    }

    /// 44pt 点按区域、17pt 图标，文字颜色（不跟随强调色）
    static func iconButton(_ symbol: String, label: String) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .medium))
        config.baseForegroundColor = .label
        config.contentInsets = .zero
        let button = UIButton(configuration: config)
        button.accessibilityLabel = label
        return button
    }

    /// 胶囊里的下拉按钮：文字 + 上下箭头
    static func pillConfiguration(_ title: String) -> UIButton.Configuration {
        var config = UIButton.Configuration.plain()
        var text = AttributedString(title)
        text.font = UIFont.systemFont(ofSize: 17, weight: .medium)
        config.attributedTitle = text
        config.image = UIImage(systemName: "chevron.up.chevron.down", withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
        config.imagePlacement = .trailing
        config.imagePadding = 4
        config.baseForegroundColor = .label
        config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 14)
        return config
    }

    /// 放得下按钮内容的胶囊宽度，至少是圆形按钮那么宽
    static func pillWidth(_ button: UIButton) -> CGFloat {
        max(size, ceil(button.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: size)).width))
    }

    /// 每次打开菜单时才生成菜单项，显示的永远是当时的状态
    static func deferredMenu(_ items: @escaping @MainActor () -> [UIMenuElement]) -> UIMenu {
        UIMenu(children: [
            UIDeferredMenuElement.uncached { completion in
                MainActor.assumeIsolated { completion(items()) }
            }
        ])
    }

    /// 分开 / 合上：带一点回弹，分出来时弹一下
    static func morph(_ changes: @escaping () -> Void) {
        let options: UIView.AnimationOptions = [.beginFromCurrentState, .allowUserInteraction]
        if UIAccessibility.isReduceMotionEnabled {
            UIView.animate(withDuration: 0.25, delay: 0, options: options, animations: changes)
        } else {
            UIView.animate(springDuration: 0.55, bounce: 0.3, initialSpringVelocity: 0, delay: 0, options: options, animations: changes)
        }
    }

    /// 胶囊里的内容换成另一个：短一点的淡入淡出
    static func fade(delay: Double = 0, _ changes: @escaping () -> Void) {
        UIView.animate(withDuration: 0.2, delay: delay, options: [.beginFromCurrentState, .allowUserInteraction], animations: changes)
    }

    /// 摆放可能带着缩放的视图：用 bounds 和 center，不直接设 frame
    static func place(_ view: UIView, _ rect: CGRect) {
        if view.bounds.size != rect.size { view.bounds = CGRect(origin: .zero, size: rect.size) }
        view.center = CGPoint(x: rect.midX, y: rect.midY)
    }
}
