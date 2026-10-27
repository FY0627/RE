import SwiftUI
import UIKit
import BKModel

/// 卡片详情里随数据变化的数字。详情内容和资产页右上角的「更多」菜单都读它。
@MainActor
@Observable
final class WalletDetailModel {
    var pendingCount = 0
    var recordTotal = 0
    var hasRecords = true
}

/// 卡片详情的滚动列表（UIKit）：顶部给选中的卡留出位置，下面是余额等内容（`AccountDetailSummary`）和流水。
///
/// 卡片本身不在列表里，画在列表上层（`WalletController`），按这里的滚动距离摆放：
/// 卡片和内容一起滚动；在顶部往下拉时卡片不动，只有下面的内容被拉开。
///
/// 每一格仍由 SwiftUI 画，放在关掉安全区的 `UIHostingController` 里：格子滚到状态栏下面时内容不移动、不重新布局。
/// 格子高度事先量好（流水行只取决于有没有备注和系统字号），列表不做自适应高度：滚动时不再量高度、不改布局，
/// 也不会因为格子高度随位置变化而卡在布局循环里。
///
/// 打开时第一页流水、笔数和待处理数量都读到后，内容整块从屏幕底下升上来；返回时整块退到屏幕底下。
/// 两个动画都只动列表的显示位置（Core Animation），升起途中也能滚动、点按。
@MainActor
final class WalletDetailList: NSObject, UICollectionViewDelegateFlowLayout {
    enum Section: Int {
        case card, summary, records
    }

    enum Item: Hashable {
        case card
        case summary
        case record(String)
    }

    let collectionView: UICollectionView
    /// 列表滚动了：卡片跟着移动
    var onScroll: () -> Void = {}
    var onSelectRecord: (RecordRow) -> Void = { _ in }
    var onOpenPending: () -> Void = {}
    var onEditOpeningBalance: (CurrencyCode) -> Void = { _ in }
    /// 读屏激活顶部的卡片：返回卡包
    var onActivateCard: () -> Void = {}

    private let store: LedgerStore
    private let model: WalletDetailModel
    /// 格子里的 SwiftUI 宿主挂在它下面，跟随它的外观和字号
    private unowned let parent: UIViewController
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    /// 量格子高度用，不显示
    private let sizer: UIHostingController<AnyView>
    private var summaryHeight: CGFloat = 0
    /// 流水行的高度，按有没有备注各量一次；宽度或系统字号变了清空
    private var rowHeights: [Bool: CGFloat] = [:]
    private var account: Account?
    private var rows: [RecordRow] = []
    private var rowsByID: [String: RecordRow] = [:]
    private var hasMore = false
    private var loadingMore = false
    private var loadTask: Task<Void, Never>?
    /// 每次重新读第一页 +1；读数据的任务据此判断结果是否过时
    private var session = 0
    /// 余额和流水是否已经显示（升起之后，到关闭后清空之前）
    private var contentShown = false

    /// 每页流水条数（`LedgerStore.records(accountID:after:)`）
    private static let pageSize = 40

    init(store: LedgerStore, model: WalletDetailModel, parent: UIViewController) {
        self.store = store
        self.model = model
        self.parent = parent
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .vertical
        layout.minimumInteritemSpacing = 0
        layout.minimumLineSpacing = 0
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        sizer = UIHostingController(rootView: AnyView(EmptyView()))
        super.init()

        sizer.safeAreaRegions = []
        sizer.view.isHidden = true
        parent.addChild(sizer)
        parent.view.addSubview(sizer.view)
        sizer.didMove(toParent: parent)

        collectionView.backgroundColor = .clear
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.selfSizingInvalidation = .disabled
        collectionView.alwaysBounceVertical = true
        collectionView.showsVerticalScrollIndicator = false
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.scrollsToTop = false
        // 最后一行下面留白（详情里标签栏是隐藏的）
        collectionView.contentInset.bottom = 48
        collectionView.delegate = self

        let cardSlot = UICollectionView.CellRegistration<CardSlotCell, Item> { [weak self] cell, _, _ in
            cell.accessibilityLabel = self?.cardLabel
            cell.activate = { [weak self] in self?.onActivateCard() }
        }
        let summary = UICollectionView.CellRegistration<HostingCell, Item> { [weak self] cell, _, _ in
            guard let self, let account = self.account else { return }
            cell.show(self.summaryView(account), parent: self.parent)
        }
        let record = UICollectionView.CellRegistration<HostingCell, Item> { [weak self] cell, _, item in
            guard let self, case .record(let id) = item, let row = self.rowsByID[id] else { return }
            cell.show(RecordRowView(row: row, showAccount: false, boxed: true), parent: self.parent)
        }
        dataSource = UICollectionViewDiffableDataSource<Section, Item>(collectionView: collectionView) { collectionView, indexPath, item in
            switch item {
            case .card:
                return collectionView.dequeueConfiguredReusableCell(using: cardSlot, for: indexPath, item: item)
            case .summary:
                return collectionView.dequeueConfiguredReusableCell(using: summary, for: indexPath, item: item)
            case .record:
                return collectionView.dequeueConfiguredReusableCell(using: record, for: indexPath, item: item)
            }
        }
        applySnapshot(reconfigure: false)
    }

    private func summaryView(_ account: Account) -> some View {
        AccountDetailSummary(
            accountID: account.id,
            model: model,
            openPending: { [weak self] in self?.onOpenPending() },
            editOpeningBalance: { [weak self] currency in self?.onEditOpeningBalance(currency) }
        )
        .environment(store)
    }

    // MARK: 格子尺寸

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        let width = collectionView.bounds.width
        let contentWidth = AppLayout.cardWidth(width)
        switch dataSource.itemIdentifier(for: indexPath) {
        case .card:
            // 卡片画在列表上层，这里只留出位置：顶部按钮一行 + 卡片
            return CGSize(width: width, height: AppLayout.detailTop + AppLayout.cardHeight(width))
        case .summary:
            return CGSize(width: contentWidth, height: summaryHeight)
        case .record(let id):
            return CGSize(width: contentWidth, height: rowHeight(rowsByID[id], width: contentWidth))
        case nil:
            return CGSize(width: contentWidth, height: 1)
        }
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, insetForSectionAt section: Int) -> UIEdgeInsets {
        let inset = AppLayout.cardInset
        switch Section(rawValue: section) {
        case .summary:
            return UIEdgeInsets(top: 8, left: inset, bottom: 0, right: inset)
        case .records:
            return UIEdgeInsets(top: 0, left: inset, bottom: 0, right: inset)
        default:
            return .zero
        }
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, minimumLineSpacingForSectionAt section: Int) -> CGFloat {
        Section(rawValue: section) == .records ? 8 : 0
    }

    /// 宽度或系统字号变了：重新量高度
    func invalidateSizes() {
        rowHeights = [:]
        updateSummaryHeight()
        collectionView.collectionViewLayout.invalidateLayout()
    }

    private func measure(_ content: some View, width: CGFloat) -> CGFloat {
        sizer.rootView = AnyView(content)
        return sizer.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height.rounded(.up)
    }

    /// 流水行每一部分都只有一行，高度只取决于有没有备注（和系统字号）
    private func rowHeight(_ row: RecordRow?, width: CGFloat) -> CGFloat {
        guard let row else { return 1 }
        let hasNote = !row.record.note.isEmpty
        if let height = rowHeights[hasNote] { return height }
        let height = measure(RecordRowView(row: row, showAccount: false, boxed: true), width: width)
        rowHeights[hasNote] = height
        return height
    }

    private func updateSummaryHeight() {
        guard contentShown, let account else {
            summaryHeight = 0
            return
        }
        summaryHeight = measure(summaryView(account), width: AppLayout.cardWidth(collectionView.bounds.width))
    }

    // MARK: 滚动

    /// 往上滚动的距离；在顶部往下拉时为负
    var scrolledDistance: CGFloat { collectionView.contentOffset.y + collectionView.contentInset.top }

    /// 顶部留出状态栏，滚动距离不变
    func setTopInset(_ top: CGFloat) {
        guard collectionView.contentInset.top != top else { return }
        let scrolled = scrolledDistance
        collectionView.contentInset.top = top
        collectionView.contentOffset.y = scrolled - top
    }

    /// 停止惯性滚动：返回时卡片从它现在的位置回卡包
    func stopScrolling() {
        collectionView.setContentOffset(collectionView.contentOffset, animated: false)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        onScroll()
    }

    // MARK: 打开 / 关闭

    /// 打开一张卡的详情。返回途中再点同一张卡、内容还没清空时，内容从当前位置升回来；
    /// 否则回到顶部，读到第一页流水后内容从屏幕底下升上来
    func open(_ account: Account) {
        collectionView.isHidden = false
        collectionView.isUserInteractionEnabled = true
        collectionView.scrollsToTop = true
        collectionView.accessibilityElementsHidden = false
        let layer = collectionView.layer
        if contentShown, self.account?.id == account.id {
            let timing = CardMotion.entrance(reduceMotion: UIAccessibility.isReduceMotionEnabled)
            CardMotion.setTransform(layer, CATransform3DIdentity, timing: timing)
            CardMotion.setOpacity(layer, 1, timing: timing)
            return
        }
        self.account = account
        contentShown = false
        rows = []
        rowsByID = [:]
        layer.removeAllAnimations()
        layer.transform = CATransform3DIdentity
        layer.opacity = 1
        applySnapshot(reconfigure: false)
        collectionView.contentOffset = CGPoint(x: 0, y: -collectionView.contentInset.top)
        load()
    }

    /// 返回：内容整块退到屏幕底下（和入场相反，与卡片同一个弹簧），不再接收触摸
    func close() {
        loadTask?.cancel()
        loadTask = nil
        stopScrolling()
        collectionView.isUserInteractionEnabled = false
        collectionView.scrollsToTop = false
        collectionView.accessibilityElementsHidden = true
        let layer = collectionView.layer
        if UIAccessibility.isReduceMotionEnabled {
            CardMotion.setOpacity(layer, 0, timing: .easeIn(0.15))
        } else {
            let away = CATransform3DMakeTranslation(0, collectionView.bounds.height, 0)
            CardMotion.setTransform(layer, away, timing: CardMotion.transition(reduceMotion: false))
        }
    }

    /// 返回动画结束：隐藏并清空，下次打开从头开始
    func finishClose() {
        session += 1
        loadTask?.cancel()
        loadTask = nil
        account = nil
        contentShown = false
        rows = []
        rowsByID = [:]
        hasMore = false
        loadingMore = false
        collectionView.isHidden = true
        let layer = collectionView.layer
        layer.removeAllAnimations()
        layer.transform = CATransform3DIdentity
        layer.opacity = 1
        applySnapshot(reconfigure: false)
    }

    /// 详情打开时卡片信息变了（改名、停用）
    func update(account: Account) {
        guard self.account?.id == account.id, self.account != account else { return }
        self.account = account
        applySnapshot(reconfigure: true)
    }

    /// 数据变了（新流水、改了初始余额、处理了待处理账单）：重新读第一页
    func reload() {
        guard account != nil, contentShown || loadTask != nil else { return }
        load()
    }

    // MARK: 数据

    /// 读第一页流水、笔数和待处理数量，读到后一起显示；第一次显示时内容从屏幕底下升上来
    private func load() {
        guard let account else { return }
        let id = account.id
        session += 1
        let session = session
        loadingMore = false
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self else { return }
            let first = await self.store.records(accountID: id, after: nil)
            let total = await self.store.recordCount(accountID: id)
            let pending = await self.pendingCount(accountID: id)
            guard !Task.isCancelled, session == self.session else { return }
            self.loadTask = nil
            var seen = Set<String>()
            self.rows = first.filter { seen.insert($0.id).inserted }
            self.rowsByID = Dictionary(uniqueKeysWithValues: self.rows.map { ($0.id, $0) })
            self.hasMore = first.count == WalletDetailList.pageSize
            // 只在变化时写入：写入就会让读它的 SwiftUI 视图重新计算
            if self.model.recordTotal != total { self.model.recordTotal = total }
            if self.model.pendingCount != pending { self.model.pendingCount = pending }
            if self.model.hasRecords == first.isEmpty { self.model.hasRecords = !first.isEmpty }
            let reveal = !self.contentShown
            self.contentShown = true
            self.applySnapshot(reconfigure: true)
            if reveal {
                CardMotion.rise(
                    self.collectionView.layer,
                    from: self.collectionView.bounds.height,
                    timing: CardMotion.entrance(reduceMotion: UIAccessibility.isReduceMotionEnabled)
                )
            }
        }
    }

    private func pendingCount(accountID: String) async -> Int {
        guard store.pendingCount > 0, let account = store.account(id: accountID) else { return 0 }
        return await store.pendingItems().filter { PendingView.belongs($0, to: account) }.count
    }

    private func loadMore() {
        guard hasMore, !loadingMore, let account, let last = rows.last else { return }
        loadingMore = true
        let session = session
        Task { [weak self] in
            guard let self else { return }
            let page = await self.store.records(accountID: account.id, after: last)
            guard session == self.session else { return }
            self.loadingMore = false
            self.hasMore = page.count == WalletDetailList.pageSize
            let fresh = page.filter { self.rowsByID[$0.id] == nil }
            guard !fresh.isEmpty else { return }
            self.rows += fresh
            for row in fresh { self.rowsByID[row.id] = row }
            self.applySnapshot(reconfigure: false)
        }
    }

    private func applySnapshot(reconfigure: Bool) {
        updateSummaryHeight()
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections([.card])
        snapshot.appendItems([.card], toSection: .card)
        if contentShown {
            snapshot.appendSections([.summary])
            snapshot.appendItems([.summary], toSection: .summary)
            if !rows.isEmpty {
                snapshot.appendSections([.records])
                snapshot.appendItems(rows.map { Item.record($0.id) }, toSection: .records)
            }
        }
        if reconfigure {
            // 已经显示的格子内容可能变了（备注、状态、余额），重新配置；新出现的格子本来就会配置
            let shown = Set(dataSource.snapshot().itemIdentifiers)
            snapshot.reconfigureItems(snapshot.itemIdentifiers.filter { shown.contains($0) })
        }
        dataSource.apply(snapshot, animatingDifferences: false)
        if reconfigure {
            // 余额区、有没有备注变了时高度也会变；列表不自己量高度，要重新取一次
            collectionView.collectionViewLayout.invalidateLayout()
        }
    }

    private var cardLabel: String? {
        guard let account else { return nil }
        let balance = store.balances[account.id]?.cardText ?? "余额未知"
        return "\(account.bankName) \(account.cardType.displayName) 尾号\(account.last4)，\(balance)"
    }

    // MARK: 点按

    func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        isRecord(indexPath)
    }

    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        isRecord(indexPath)
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: false)
        guard case .record(let id) = dataSource.itemIdentifier(for: indexPath), let row = rowsByID[id] else { return }
        onSelectRecord(row)
    }

    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        guard case .record(let id) = dataSource.itemIdentifier(for: indexPath), id == rows.last?.id else { return }
        loadMore()
    }

    private func isRecord(_ indexPath: IndexPath) -> Bool {
        if case .record = dataSource.itemIdentifier(for: indexPath) { return true }
        return false
    }
}

/// 一格由 SwiftUI 画的内容。用 `UIHostingController` 是为了关掉安全区：
/// 格子滚到状态栏下面时，SwiftUI 不会因为安全区变化把内容往下推、重新布局
private final class HostingCell: UICollectionViewCell {
    private var host: UIHostingController<AnyView>?

    func show(_ content: some View, parent: UIViewController) {
        let view = AnyView(content)
        if let host {
            host.rootView = view
            return
        }
        let host = UIHostingController(rootView: view)
        host.safeAreaRegions = []
        host.view.backgroundColor = .clear
        host.view.frame = contentView.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        parent.addChild(host)
        contentView.addSubview(host.view)
        host.didMove(toParent: parent)
        self.host = host
    }
}

/// 详情顶部给选中卡片留的位置。卡片画在列表上层；读屏时这里代表卡片，激活即返回卡包
private final class CardSlotCell: UICollectionViewCell {
    var activate: () -> Void = {}

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityHint = "返回卡包"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func accessibilityActivate() -> Bool {
        activate()
        return true
    }
}
