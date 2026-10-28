import UIKit

/// 资产页顶部的玻璃按钮（UIKit 液态玻璃，共用部分在 `GlassControls`）。
///
/// 卡包：右边「+」和「更多」合成一个胶囊。打开详情：「+」那一半像水滴一样从胶囊里分出来、弹一下，
/// 变成选时间段的胶囊按钮（写着「全部」「本月」……）；左边出现返回按钮。返回时时间段胶囊并回去，变回「+」。
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

    static let height = GlassControls.size

    private let container = GlassControls.container()
    /// 卡包里没有，打开详情时「凝结」出来
    private let backGlass = GlassControls.capsule(nil)
    /// 卡包里是「+」，详情里是时间段
    private let leadGlass = GlassControls.capsule(GlassControls.glass())
    private let moreGlass = GlassControls.capsule(GlassControls.glass())
    private let backButton = GlassControls.iconButton("chevron.left", label: "返回卡包")
    private let addButton = GlassControls.iconButton("plus", label: "添加银行卡")
    private let moreButton = GlassControls.iconButton("ellipsis", label: "管理银行卡")
    private let periodButton = UIButton(configuration: GlassControls.pillConfiguration(""))

    private(set) var isDetail = false
    private var periodTitle = ""

    override init(frame: CGRect) {
        super.init(frame: frame)
        container.frame = bounds
        container.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(container)
        for glass in [backGlass, leadGlass, moreGlass] {
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
        periodButton.showsMenuAsPrimaryAction = true
        periodButton.menu = GlassControls.deferredMenu { [weak self] in self?.periodMenu() ?? [] }

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
        GlassControls.morph {
            self.applyLayout()
            self.applyGlass()
        }
        let detailContent: [UIView] = [backButton, periodButton]
        GlassControls.swapContent(show: detail ? detailContent : [addButton], hide: detail ? [addButton] : detailContent)
    }

    /// 时间段胶囊上写的字；宽度跟着变
    func setPeriodTitle(_ title: String, animated: Bool) {
        guard title != periodTitle else { return }
        periodTitle = title
        UIView.performWithoutAnimation {
            periodButton.configuration = GlassControls.pillConfiguration(title)
            periodButton.layoutIfNeeded()
        }
        guard isDetail else { return }
        if animated, window != nil {
            GlassControls.morph { self.applyLayout() }
        } else {
            applyLayout()
        }
    }

    // MARK: 布局

    override func layoutSubviews() {
        super.layoutSubviews()
        applyLayout()
    }

    /// 按当前状态摆放；在动画里调用时就是动画的终点
    private func applyLayout() {
        let width = bounds.width, size = GlassControls.size
        GlassControls.place(backGlass, CGRect(x: 0, y: 0, width: size, height: size))
        GlassControls.place(moreGlass, CGRect(x: width - size, y: 0, width: size, height: size))
        if isDetail {
            let pill = GlassControls.pillWidth(periodButton)
            GlassControls.place(leadGlass, CGRect(x: width - size - GlassControls.gap - pill, y: 0, width: pill, height: size))
        } else {
            // 一直伸到「更多」的右边：重叠的部分合成一块玻璃，看起来是一整个胶囊
            GlassControls.place(leadGlass, CGRect(x: width - 2 * size, y: 0, width: 2 * size, height: size))
        }
        backButton.frame = CGRect(x: 0, y: 0, width: size, height: size)
        moreButton.frame = CGRect(x: 0, y: 0, width: size, height: size)
        addButton.frame = CGRect(x: 0, y: 0, width: size, height: size)
        periodButton.frame = CGRect(origin: .zero, size: leadGlass.bounds.size)
    }

    /// 返回按钮的玻璃：设成玻璃效果时系统播放「凝结」动画，设成 nil 时「消散」；同时从小放大
    private func applyGlass() {
        backGlass.effect = isDetail ? GlassControls.glass() : nil
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
        addButton.isUserInteractionEnabled = !isDetail
        periodButton.isUserInteractionEnabled = isDetail
        moreButton.accessibilityLabel = isDetail ? "更多" : "管理银行卡"
        moreButton.showsMenuAsPrimaryAction = isDetail
        moreButton.menu = isDetail ? GlassControls.deferredMenu { [weak self] in self?.moreMenu() ?? [] } : nil
        accessibilityElements = isDetail ? [backButton, periodButton, moreButton] : [addButton, moreButton]
    }

    /// 只有按钮的玻璃接收触摸，空白处不挡住下面的卡包和详情
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let hit = super.hitTest(point, with: event) else { return nil }
        return [backGlass, leadGlass, moreGlass].contains(where: { hit.isDescendant(of: $0) }) ? hit : nil
    }
}
