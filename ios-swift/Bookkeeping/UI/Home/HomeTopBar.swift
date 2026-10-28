import SwiftUI
import UIKit

/// 首页顶部一行，放进 SwiftUI 的首页。搜索框里打的字和「全部 / 支出 / 收入」通过绑定交给首页去查。
struct HomeTopBar: UIViewRepresentable {
    @Binding var query: String
    @Binding var scope: HomeView.SearchScope

    func makeUIView(context: Context) -> HomeTopBarView {
        HomeTopBarView()
    }

    func updateUIView(_ view: HomeTopBarView, context: Context) {
        view.onQueryChange = { query = $0 }
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
/// 平时：左边大标题「日常记账」（和资产页的「资产」一样的位置和字号），右边圆形搜索按钮。
/// 点搜索：搜索按钮向左展开成搜索框；最左边像水滴一样分出「全部 / 支出 / 收入」的下拉按钮，代替标题；
/// 右边分出圆形的关闭按钮。点关闭，三块玻璃按原路并回搜索按钮，标题回来。
@MainActor
final class HomeTopBarView: UIView, UITextFieldDelegate {
    var onQueryChange: (String) -> Void = { _ in }
    /// 关闭搜索：清空关键字，回到「全部」
    var onClose: () -> Void = {}
    /// 「全部 / 支出 / 收入」的菜单项，每次打开菜单时生成
    var scopeMenu: () -> [UIMenuElement] = { [] }

    static let height = GlassControls.size

    private let titleLabel = UILabel()
    private let container = GlassControls.container()
    // 平时三块玻璃叠在搜索按钮的位置，合成一个圆
    private let scopeGlass = GlassControls.capsule(GlassControls.glass())
    private let closeGlass = GlassControls.capsule(GlassControls.glass())
    private let searchGlass = GlassControls.capsule(GlassControls.glass())
    private let scopeButton = UIButton(configuration: GlassControls.pillConfiguration("全部"))
    private let closeButton = GlassControls.iconButton("xmark", label: "关闭搜索")
    /// 平时盖满搜索按钮，点一下展开
    private let searchButton = UIButton(type: .custom)
    private let searchIcon = UIImageView(image: UIImage(
        systemName: "magnifyingglass",
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .medium)
    ))
    private let textField = UITextField()

    private(set) var isSearching = false
    private var scopeTitle = "全部"

    /// 放大镜离搜索框左边的距离：和圆形按钮里居中的位置差不多，展开时放大镜不跳
    private static let iconInset: CGFloat = 13.5

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
        for glass in [scopeGlass, closeGlass, searchGlass] {
            container.contentView.addSubview(glass)
        }
        scopeGlass.contentView.addSubview(scopeButton)
        closeGlass.contentView.addSubview(closeButton)
        searchGlass.contentView.addSubview(searchIcon)
        searchGlass.contentView.addSubview(textField)
        searchGlass.contentView.addSubview(searchButton)

        searchIcon.tintColor = .label
        searchIcon.contentMode = .center
        searchButton.accessibilityLabel = "搜索流水"
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

    private func setSearching(_ searching: Bool) {
        guard searching != isSearching else { return }
        isSearching = searching
        applyInteraction()
        if !searching {
            textField.resignFirstResponder()
            textField.text = ""
            onClose()
        }
        if window != nil {
            GlassControls.morph { self.applyLayout() }
            let searchContent: [UIView] = [scopeButton, closeButton, textField]
            GlassControls.swapContent(show: searching ? searchContent : [titleLabel], hide: searching ? [titleLabel] : searchContent)
        } else {
            applyLayout()
            applyContent()
        }
        // 搜索框已经是展开后的大小：键盘和玻璃同时出来
        if searching { textField.becomeFirstResponder() }
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

    /// 按当前状态摆放；在动画里调用时就是动画的终点
    private func applyLayout() {
        let width = bounds.width, size = GlassControls.size, gap = GlassControls.gap
        let circle = CGRect(x: width - size, y: 0, width: size, height: size)
        titleLabel.frame = CGRect(x: 4, y: 0, width: max(0, width - size - gap - 4), height: size)
        GlassControls.place(closeGlass, circle)
        if isSearching {
            let pill = GlassControls.pillWidth(scopeButton)
            GlassControls.place(scopeGlass, CGRect(x: 0, y: 0, width: pill, height: size))
            let left = pill + gap
            GlassControls.place(searchGlass, CGRect(x: left, y: 0, width: max(size, width - size - gap - left), height: size))
        } else {
            GlassControls.place(scopeGlass, circle)
            GlassControls.place(searchGlass, circle)
        }
        scopeButton.frame = CGRect(origin: .zero, size: scopeGlass.bounds.size)
        closeButton.frame = CGRect(x: 0, y: 0, width: size, height: size)
        let field = searchGlass.bounds.size
        searchButton.frame = CGRect(origin: .zero, size: field)
        searchIcon.frame = CGRect(x: Self.iconInset, y: 0, width: 17, height: size)
        let textX = Self.iconInset + 17 + 8
        textField.frame = CGRect(x: textX, y: 0, width: max(0, field.width - textX - 10), height: size)
    }

    private func applyContent() {
        titleLabel.alpha = isSearching ? 0 : 1
        scopeButton.alpha = isSearching ? 1 : 0
        closeButton.alpha = isSearching ? 1 : 0
        textField.alpha = isSearching ? 1 : 0
    }

    /// 只有看得见的按钮接收点按和读屏
    private func applyInteraction() {
        searchButton.isHidden = isSearching
        scopeButton.isUserInteractionEnabled = isSearching
        closeButton.isUserInteractionEnabled = isSearching
        textField.isUserInteractionEnabled = isSearching
        accessibilityElements = isSearching ? [scopeButton, textField, closeButton] : [titleLabel, searchButton]
    }

    /// 只有玻璃接收触摸，标题和空白处不挡住下面的列表
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let hit = super.hitTest(point, with: event) else { return nil }
        return [scopeGlass, closeGlass, searchGlass].contains(where: { hit.isDescendant(of: $0) }) ? hit : nil
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
