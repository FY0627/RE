import SwiftUI
import UIKit

/// 首页顶部一行，放进 SwiftUI 的首页。搜索框里打的字和「全部 / 支出 / 收入 / 转帐」通过绑定交给首页去查；「+」是记一笔。
struct HomeTopBar: UIViewRepresentable {
    @Binding var query: String
    @Binding var scope: HomeView.SearchScope
    let add: () -> Void

    func makeUIView(context: Context) -> HomeTopBarView {
        HomeTopBarView()
    }

    func updateUIView(_ view: HomeTopBarView, context: Context) {
        view.onQueryChange = { query = $0 }
        view.onAdd = add
        view.onClose = {
            query = ""
            scope = .all
        }
        view.scopeMenu = {
            HomeView.SearchScope.allCases.map { option -> UIMenuElement in
                UIAction(title: option.title, state: option == scope ? .on : .off) { _ in scope = option }
            }
        }
        view.setScopeTitle(scope.title)
        view.setQuery(query)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: HomeTopBarView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 320, height: HomeTopBarView.height)
    }
}

/// 首页顶部一行（UIKit 液态玻璃，和资产页顶部按钮同一种做法，共用部分在 `GlassControls`）。
///
/// 平时：左边大标题「日常记账」（和资产页的「资产」一样的位置和字号），右边「+」（记一笔）和搜索两个圆形按钮。
/// 点搜索：右边的圆留在原地变成关闭按钮，「+」并进这个圆里，搜索框从圆里像水滴一样向左分出来，
/// 最左边再分出「全部 / 支出 / 收入 / 转帐」的下拉按钮，代替标题。
/// 点关闭：把展开动画倒过来播放，搜索框和下拉按钮沿原路缩回圆里，「+」从圆里分出来回到原处，标题回来。
///
/// 手指按住的那块玻璃（右边的圆）始终不动：按住时玻璃会鼓起来，这时让它移动，看不出和别的玻璃融合、分开。
@MainActor
final class HomeTopBarView: UIView, UITextFieldDelegate {
    var onQueryChange: (String) -> Void = { _ in }
    /// 关闭搜索：清空关键字，回到「全部」
    var onClose: () -> Void = {}
    /// 记一笔
    var onAdd: () -> Void = {}
    /// 「全部 / 支出 / 收入」的菜单项，每次打开菜单时生成
    var scopeMenu: () -> [UIMenuElement] = { [] }

    static let height = GlassControls.size

    private let titleLabel = UILabel()
    private let container = GlassControls.container()
    /// 平时没有玻璃效果，叠在圆的下面；展开前一刻加上玻璃，和圆完全重叠，再一起分开（`setSplit`）
    private let scopeGlass = GlassControls.capsule(nil)
    private let fieldGlass = GlassControls.capsule(nil)
    /// 右边的圆：平时是搜索按钮，展开后是关闭按钮
    private let circleGlass = GlassControls.capsule(GlassControls.glass())
    /// 搜索左边的「+」：搜索时并进右边的圆，停稳后去掉玻璃效果（叠在圆下面）
    private let addGlass = GlassControls.capsule(GlassControls.glass())
    private let addButton = GlassControls.iconButton("plus", label: "记一笔")
    private let searchButton = GlassControls.iconButton("magnifyingglass", label: "搜索流水")
    private let closeButton = GlassControls.iconButton("xmark", label: "关闭搜索")
    private let scopeButton = UIButton(configuration: GlassControls.pillConfiguration("全部"))
    private let fieldIcon = UIImageView(image: UIImage(
        systemName: "magnifyingglass",
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .medium)
    ))
    private let textField = UITextField()

    private(set) var isSearching = false
    private var scopeTitle = "全部"
    /// 上一次展开开始的时间：还没停稳时合上要从半路接着走
    private var lastMorph: CFTimeInterval = 0

    /// 搜索框里放大镜离左边的距离
    private static let iconInset: CGFloat = 14

    override init(frame: CGRect) {
        super.init(frame: frame)
        let metrics = UIFontMetrics(forTextStyle: .largeTitle)
        titleLabel.font = metrics.scaledFont(for: UIFont.systemFont(ofSize: 34, weight: .bold))
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.text = "日常记账"
        titleLabel.textColor = .label
        titleLabel.accessibilityTraits = .header
        addSubview(titleLabel)

        container.frame = bounds
        container.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(container)
        // 圆在最上面：平时点到的是它
        for glass in [addGlass, scopeGlass, fieldGlass, circleGlass] {
            container.contentView.addSubview(glass)
        }
        addGlass.contentView.addSubview(addButton)
        addButton.addAction(UIAction { [weak self] _ in self?.onAdd() }, for: .primaryActionTriggered)
        scopeGlass.contentView.addSubview(scopeButton)
        fieldGlass.contentView.addSubview(fieldIcon)
        fieldGlass.contentView.addSubview(textField)
        circleGlass.contentView.addSubview(searchButton)
        circleGlass.contentView.addSubview(closeButton)

        fieldIcon.tintColor = .secondaryLabel
        fieldIcon.contentMode = .center
        searchButton.addAction(UIAction { [weak self] _ in self?.setSearching(true) }, for: .primaryActionTriggered)
        closeButton.addAction(UIAction { [weak self] _ in self?.setSearching(false) }, for: .primaryActionTriggered)
        scopeButton.showsMenuAsPrimaryAction = true
        scopeButton.menu = GlassControls.deferredMenu { [weak self] in self?.scopeMenu() ?? [] }
        scopeButton.accessibilityLabel = "范围"

        textField.placeholder = "商户、备注、金额、尾号"
        textField.font = UIFont.preferredFont(forTextStyle: .body)
        textField.adjustsFontForContentSizeCategory = true
        textField.textColor = .label
        textField.clearButtonMode = .whileEditing
        textField.returnKeyType = .search
        textField.autocorrectionType = .no
        textField.autocapitalizationType = .none
        textField.spellCheckingType = .no
        textField.delegate = self
        textField.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.onQueryChange(self.textField.text ?? "")
        }, for: .editingChanged)

        setSplit(false)
        applyLayout()
        applyContent()
        applyInteraction()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: Self.height)
    }

    // MARK: 状态

    private var searchContent: [UIView] { [scopeButton, closeButton, fieldIcon, textField] }
    private var idleContent: [UIView] { [titleLabel, addButton, searchButton] }

    private func setSearching(_ searching: Bool) {
        guard searching != isSearching else { return }
        isSearching = searching
        applyInteraction()
        if !searching {
            textField.resignFirstResponder()
            textField.text = ""
            onClose()
        }
        guard window != nil else {
            setSplit(searching)
            GlassControls.setGlass([addGlass], !searching)
            applyLayout()
            applyContent()
            if searching { textField.becomeFirstResponder() }
            return
        }
        if searching {
            setSplit(true)
            lastMorph = CACurrentMediaTime()
            GlassControls.morph({ self.applyLayout() }, completion: { [weak self] finished in
                // 「+」并进圆里停稳了：只留圆这一块玻璃
                guard let self, finished, self.isSearching else { return }
                GlassControls.setGlass([self.addGlass], false)
            })
            GlassControls.swapContent(show: searchContent, hide: idleContent)
            // 搜索框已经是展开后的大小：键盘和玻璃同时出来
            textField.becomeFirstResponder()
            return
        }
        let finish: (Bool) -> Void = { [weak self] finished in
            // 缩回去停稳了：只留圆这一块玻璃（中途又展开了就不动）
            guard let self, finished, !self.isSearching else { return }
            self.setSplit(false)
        }
        // 「+」先和圆重叠着加回玻璃，再一起分开
        GlassControls.setGlass([addGlass], true)
        if CACurrentMediaTime() - lastMorph >= GlassControls.morphSettle {
            // 展开已经停稳：把展开动画倒过来播放
            let scopeFrom = GlassControls.frame(of: scopeGlass), fieldFrom = GlassControls.frame(of: fieldGlass)
            let circle = circleFrame, add = addFrame
            GlassControls.reverseMorph({ progress in
                self.placeMoving(
                    scope: GlassControls.lerp(scopeFrom, circle, progress),
                    field: GlassControls.lerp(fieldFrom, circle, progress),
                    add: GlassControls.lerp(circle, add, progress)
                )
            }, completion: finish)
        } else {
            // 还在展开的半路：从当前位置直接回去，不回弹
            GlassControls.morph({ self.applyLayout() }, bounce: 0, completion: finish)
        }
        GlassControls.swapContent(show: idleContent, hide: searchContent)
    }

    /// 搜索框和下拉按钮是不是单独的玻璃（展开时和展开、合上的途中）
    private func setSplit(_ split: Bool) {
        GlassControls.setGlass([scopeGlass, fieldGlass], split)
        scopeGlass.isUserInteractionEnabled = split
        fieldGlass.isUserInteractionEnabled = split
    }

    func setScopeTitle(_ title: String) {
        guard title != scopeTitle else { return }
        scopeTitle = title
        UIView.performWithoutAnimation {
            scopeButton.configuration = GlassControls.pillConfiguration(title)
            scopeButton.layoutIfNeeded()
        }
        setNeedsLayout()
    }

    /// 首页改了关键字（例如关闭后清空）。正在打拼音时不改，免得打断输入法
    func setQuery(_ query: String) {
        guard textField.text != query, textField.markedTextRange == nil else { return }
        textField.text = query
    }

    // MARK: 布局

    override func layoutSubviews() {
        super.layoutSubviews()
        applyLayout()
    }

    private var circleFrame: CGRect {
        CGRect(x: bounds.width - GlassControls.size, y: 0, width: GlassControls.size, height: GlassControls.size)
    }

    /// 「+」平时的位置：搜索按钮左边，隔开一个间距（不和圆连在一起）
    private var addFrame: CGRect {
        CGRect(x: bounds.width - 2 * GlassControls.size - GlassControls.gap, y: 0, width: GlassControls.size, height: GlassControls.size)
    }

    /// 按当前状态摆放；在动画里调用时就是动画的终点
    private func applyLayout() {
        let size = GlassControls.size, gap = GlassControls.gap
        titleLabel.frame = CGRect(x: 4, y: 0, width: max(0, bounds.width - 2 * size - 2 * gap - 4), height: size)
        GlassControls.place(circleGlass, circleFrame)
        searchButton.frame = CGRect(x: 0, y: 0, width: size, height: size)
        closeButton.frame = CGRect(x: 0, y: 0, width: size, height: size)
        addButton.frame = CGRect(x: 0, y: 0, width: size, height: size)
        guard isSearching else {
            placeMoving(scope: circleFrame, field: circleFrame, add: addFrame)
            return
        }
        let scope = CGRect(x: 0, y: 0, width: GlassControls.pillWidth(scopeButton), height: size)
        let left = scope.maxX + gap
        let field = CGRect(x: left, y: 0, width: max(size, bounds.width - size - gap - left), height: size)
        placeMoving(scope: scope, field: field, add: circleFrame)
    }

    /// 会移动的三块：下拉按钮、搜索框和「+」
    private func placeMoving(scope: CGRect, field: CGRect, add: CGRect) {
        let size = GlassControls.size
        GlassControls.place(addGlass, add)
        GlassControls.place(scopeGlass, scope)
        scopeButton.frame = CGRect(origin: .zero, size: scope.size)
        GlassControls.place(fieldGlass, field)
        fieldIcon.frame = CGRect(x: Self.iconInset, y: 0, width: 17, height: size)
        let textX = Self.iconInset + 17 + 8
        textField.frame = CGRect(x: textX, y: 0, width: max(0, field.width - textX - 10), height: size)
    }

    private func applyContent() {
        for view in idleContent { view.alpha = isSearching ? 0 : 1 }
        for view in searchContent { view.alpha = isSearching ? 1 : 0 }
    }

    /// 只有看得见的按钮接收点按和读屏
    private func applyInteraction() {
        searchButton.isUserInteractionEnabled = !isSearching
        addButton.isUserInteractionEnabled = !isSearching
        addGlass.isUserInteractionEnabled = !isSearching
        closeButton.isUserInteractionEnabled = isSearching
        scopeButton.isUserInteractionEnabled = isSearching
        textField.isUserInteractionEnabled = isSearching
        accessibilityElements = isSearching ? [scopeButton, textField, closeButton] : [titleLabel, addButton, searchButton]
    }

    /// 只有玻璃接收触摸，标题和空白处不挡住下面的列表
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let hit = super.hitTest(point, with: event) else { return nil }
        return [addGlass, scopeGlass, fieldGlass, circleGlass].contains(where: { hit.isDescendant(of: $0) }) ? hit : nil
    }

    // MARK: 输入

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }

    func textFieldShouldClear(_ textField: UITextField) -> Bool {
        onQueryChange("")
        return true
    }
}
