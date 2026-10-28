import UIKit

/// 资产页顶部的玻璃按钮（UIKit 液态玻璃）。
///
/// 卡包：右边「+」和「更多」合成一个胶囊。打开详情：「+」那一半像水滴一样从胶囊里分出来、弹一下，
/// 变成选时间段的胶囊按钮（写着「全部」「本月」……）；左边出现返回按钮。返回时时间段胶囊并回去，变回「+」。
///
/// 三块玻璃放在同一个玻璃容器（`UIGlassContainerEffect`）里：重叠或靠近时系统把它们画成一整块，
/// 分开时中间像水滴一样拉开。位置和大小用 UIKit 的弹簧动画，和卡片转场一样交给 Core Animation，
/// 由系统渲染进程播放，主线程忙也不掉帧。
@MainActor
final class WalletTopBar: UIView {
    var onBack: () -> Void = {}
    var onAdd: () -> Void = {}
    /// 卡包状态点「更多」：管理银行卡
    var onManage: () -> Void = {}
    /// 详情状态「更多」的菜单项，每次打开菜单时生成（待处理数量随时会变）
    var moreMenu: () -> [UIMenuElement] = { [] }
    /// 时间段的菜单项，每次打开菜单时生成
    var periodMenu: () -> [UIMenuElement] = { [] }

    static let height: CGFloat = 44
    private static let button: CGFloat = 44
    /// 详情里时间段胶囊和「更多」之间的空隙
    private static let gap: CGFloat = 10

    private let container = UIVisualEffectView()
    private let backGlass = UIVisualEffectView()
    /// 卡包里是「+」，详情里是时间段
    private let leadGlass = UIVisualEffectView()
    private let moreGlass = UIVisualEffectView()
    private let backButton = WalletTopBar.iconButton("chevron.left", label: "返回卡包")
    private let addButton = WalletTopBar.iconButton("plus", label: "添加银行卡")
    private let moreButton = WalletTopBar.iconButton("ellipsis", label: "管理银行卡")
    private let periodButton = UIButton(configuration: .plain())

    private(set) var isDetail = false
    private var periodTitle = ""

    override init(frame: CGRect) {
        super.init(frame: frame)
        let containerEffect = UIGlassContainerEffect()
        containerEffect.spacing = 16
        container.effect = containerEffect
        container.frame = bounds
        container.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(container)

        leadGlass.effect = Self.glass()
        moreGlass.effect = Self.glass()
        // 返回按钮的玻璃在卡包里不存在，打开详情时「凝结」出来
        for glass in [backGlass, leadGlass, moreGlass] {
            glass.cornerConfiguration = .capsule()
            container.contentView.addSubview(glass)
        }
        backGlass.contentView.addSubview(backButton)
        leadGlass.contentView.addSubview(addButton)
        leadGlass.contentView.addSubview(periodButton)
        moreGlass.contentView.addSubview(moreButton)

        backButton.addAction(UIAction { [weak self] _ in self?.onBack() }, for: .primaryActionTriggered)
        addButton.addAction(UIAction { [weak self] _ in self?.onAdd() }, for: .primaryActionTriggered)
        moreButton.addAction(UIAction { [weak self] _ in
            // 详情里「更多」直接弹出菜单，不走这里
            guard let self, !self.isDetail else { return }
            self.onManage()
        }, for: .primaryActionTriggered)

        periodButton.configuration = Self.periodConfiguration("")
        periodButton.showsMenuAsPrimaryAction = true
        periodButton.menu = Self.deferredMenu { [weak self] in self?.periodMenu() ?? [] }

        applyLayout()
        applyGlass()
        applyContent()
        applyInteraction()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: 状态

    /// 卡包 ↔ 详情。和卡片转场同时开始
    func setDetail(_ detail: Bool, animated: Bool) {
        guard detail != isDetail else { return }
        isDetail = detail
        applyInteraction()
        guard animated, window != nil else {
            applyLayout()
            applyGlass()
            applyContent()
            return
        }
        let options: UIView.AnimationOptions = [.beginFromCurrentState, .allowUserInteraction]
        if UIAccessibility.isReduceMotionEnabled {
            UIView.animate(withDuration: 0.25, delay: 0, options: options) {
                self.applyLayout()
                self.applyGlass()
            }
        } else {
            // 带一点回弹：分出来时弹一下
            UIView.animate(springDuration: 0.55, bounce: 0.3, initialSpringVelocity: 0, delay: 0, options: options) {
                self.applyLayout()
                self.applyGlass()
            }
        }
        // 胶囊里的内容换成另一个按钮：短一点的淡入淡出
        UIView.animate(withDuration: 0.2, delay: detail ? 0.06 : 0, options: options) {
            self.applyContent()
        }
    }

    /// 时间段胶囊上写的字；宽度跟着变
    func setPeriodTitle(_ title: String, animated: Bool) {
        guard title != periodTitle else { return }
        periodTitle = title
        UIView.performWithoutAnimation {
            periodButton.configuration = Self.periodConfiguration(title)
            periodButton.layoutIfNeeded()
        }
        guard isDetail else { return }
        if animated, window != nil, !UIAccessibility.isReduceMotionEnabled {
            UIView.animate(springDuration: 0.4, bounce: 0.2, initialSpringVelocity: 0, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
                self.applyLayout()
            }
        } else {
            applyLayout()
        }
    }

    // MARK: 布局

    override func layoutSubviews() {
        super.layoutSubviews()
        applyLayout()
    }

    private var pillWidth: CGFloat {
        let fitting = periodButton.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: Self.height)).width
        return max(Self.button, ceil(fitting))
    }

    /// 按当前状态摆放；在动画里调用时就是动画的终点
    private func applyLayout() {
        let width = bounds.width, size = Self.button
        place(backGlass, CGRect(x: 0, y: 0, width: size, height: size))
        place(moreGlass, CGRect(x: width - size, y: 0, width: size, height: size))
        if isDetail {
            let pill = pillWidth
            place(leadGlass, CGRect(x: width - size - Self.gap - pill, y: 0, width: pill, height: size))
        } else {
            // 一直伸到「更多」的右边：重叠的部分合成一块玻璃，看起来是一整个胶囊
            place(leadGlass, CGRect(x: width - 2 * size, y: 0, width: 2 * size, height: size))
        }
        backButton.frame = CGRect(x: 0, y: 0, width: size, height: size)
        moreButton.frame = CGRect(x: 0, y: 0, width: size, height: size)
        addButton.frame = CGRect(x: 0, y: 0, width: size, height: size)
        periodButton.frame = CGRect(origin: .zero, size: leadGlass.bounds.size)
    }

    /// 用 bounds 和 center 摆放：返回按钮的玻璃带着缩放
    private func place(_ view: UIView, _ rect: CGRect) {
        if view.bounds.size != rect.size { view.bounds = CGRect(origin: .zero, size: rect.size) }
        view.center = CGPoint(x: rect.midX, y: rect.midY)
    }

    /// 返回按钮的玻璃：设成玻璃效果时系统播放「凝结」动画，设成 nil 时「消散」；同时从小放大
    private func applyGlass() {
        backGlass.effect = isDetail ? Self.glass() : nil
        backGlass.transform = isDetail ? .identity : CGAffineTransform(scaleX: 0.6, y: 0.6)
    }

    private func applyContent() {
        backButton.alpha = isDetail ? 1 : 0
        addButton.alpha = isDetail ? 0 : 1
        periodButton.alpha = isDetail ? 1 : 0
    }

    /// 只有看得见的按钮接收点按和读屏
    private func applyInteraction() {
        backGlass.isUserInteractionEnabled = isDetail
        backButton.accessibilityElementsHidden = !isDetail
        addButton.isUserInteractionEnabled = !isDetail
        addButton.accessibilityElementsHidden = isDetail
        periodButton.isUserInteractionEnabled = isDetail
        periodButton.accessibilityElementsHidden = !isDetail
        moreButton.accessibilityLabel = isDetail ? "更多" : "管理银行卡"
        moreButton.showsMenuAsPrimaryAction = isDetail
        moreButton.menu = isDetail ? Self.deferredMenu { [weak self] in self?.moreMenu() ?? [] } : nil
        accessibilityElements = isDetail ? [backButton, periodButton, moreButton] : [addButton, moreButton]
    }

    /// 只有按钮的玻璃接收触摸，空白处不挡住下面的卡包和详情
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let hit = super.hitTest(point, with: event) else { return nil }
        return [backGlass, leadGlass, moreGlass].contains(where: { hit.isDescendant(of: $0) }) ? hit : nil
    }

    // MARK: 按钮

    private static func glass() -> UIGlassEffect {
        let effect = UIGlassEffect()
        effect.isInteractive = true
        return effect
    }

    /// 和系统导航栏按钮同样大小：44pt 点按区域，17pt 图标，文字颜色（不跟随强调色）
    private static func iconButton(_ symbol: String, label: String) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .medium))
        config.baseForegroundColor = .label
        config.contentInsets = .zero
        let button = UIButton(configuration: config)
        button.accessibilityLabel = label
        return button
    }

    private static func periodConfiguration(_ title: String) -> UIButton.Configuration {
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

    /// 每次打开菜单时才生成菜单项，显示的永远是当时的状态
    private static func deferredMenu(_ items: @escaping @MainActor () -> [UIMenuElement]) -> UIMenu {
        UIMenu(children: [
            UIDeferredMenuElement.uncached { completion in
                MainActor.assumeIsolated { completion(items()) }
            }
        ])
    }
}
