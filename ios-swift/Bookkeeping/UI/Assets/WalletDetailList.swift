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
/// 每一行仍由 SwiftUI 画（`UIHostingConfiguration`）；列表只生成屏幕上看得到的行，行会复用。
/// 打开时第一页流水、笔数和待处理数量都读到后，内容整块从屏幕底下升上来：只动列表的显示位置（Core Animation），
/// 模型位置不变，升起途中也能滚动、点按。
@MainActor
final class WalletDetailList: NSObject, UICollectionViewDelegate {
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
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
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

    init(store: LedgerStore, model: WalletDetailModel) {
        self.store = store
        self.model = model
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: WalletDetailList.makeLayout())
        super.init()
        collectionView.backgroundColor = .clear
        collectionView.contentInsetAdjustmentBehavior = .never
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
        let summary = UICollectionView.CellRegistration<UICollectionViewCell, Item> { [weak self] cell, _, _ in
            guard let self, let account = self.account else { return }
            let model = self.model
            let store = self.store
            cell.contentConfiguration = UIHostingConfiguration {
                AccountDetailSummary(
                    accountID: account.id,
                    model: model,
                    openPending: { [weak self] in self?.onOpenPending() },
                    editOpeningBalance: { [weak self] currency in self?.onEditOpeningBalance(currency) }
                )
                .environment(store)
                // 行滚到状态栏下面时内容不因安全区移动
                .ignoresSafeArea()
            }
            .margins(.all, 0)
        }
        let record = UICollectionView.CellRegistration<UICollectionViewCell, Item> { [weak self] cell, _, item in
            guard case .record(let id) = item, let row = self?.rowsByID[id] else { return }
            cell.contentConfiguration = UIHostingConfiguration {
                RecordRowView(row: row, showAccount: false, boxed: true)
                    .ignoresSafeArea()
            }
            .margins(.all, 0)
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

    /// 分组总是按「卡片位置、余额等内容、流水」的顺序出现（后两组可能没有），按序号就能知道是哪一组
    private static func makeLayout() -> UICollectionViewCompositionalLayout {
        UICollectionViewCompositionalLayout { index, environment in
            let inset = AppLayout.cardInset
            switch Section(rawValue: index) ?? .records {
            case .card:
                // 卡片画在列表上层，这里只留出位置：顶部按钮一行 + 卡片
                let height = AppLayout.detailTop + AppLayout.cardHeight(environment.container.contentSize.width)
                return WalletDetailList.section(height: .absolute(height), insets: .zero)
            case .summary:
                return WalletDetailList.section(
                    height: .estimated(320),
                    insets: NSDirectionalEdgeInsets(top: 8, leading: inset, bottom: 0, trailing: inset)
                )
            case .records:
                let section = WalletDetailList.section(
                    height: .estimated(72),
                    insets: NSDirectionalEdgeInsets(top: 0, leading: inset, bottom: 0, trailing: inset)
                )
                section.interGroupSpacing = 8
                return section
            }
        }
    }

    private static func section(height: NSCollectionLayoutDimension, insets: NSDirectionalEdgeInsets) -> NSCollectionLayoutSection {
        let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: height)
        let group = NSCollectionLayoutGroup.vertical(layoutSize: size, subitems: [NSCollectionLayoutItem(layoutSize: size)])
        let section = NSCollectionLayoutSection(group: group)
        section.contentInsets = insets
        return section
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

    /// 打开一张卡的详情。返回途中再点同一张卡、内容还在原处时，内容直接淡回来；
    /// 否则回到顶部，读到第一页流水后内容从屏幕底下升上来
    func open(_ account: Account) {
        collectionView.isHidden = false
        collectionView.isUserInteractionEnabled = true
        collectionView.scrollsToTop = true
        collectionView.accessibilityElementsHidden = false
        if contentShown, self.account?.id == account.id {
            CardMotion.setOpacity(collectionView.layer, 1, timing: .easeOut(0.2))
            return
        }
        self.account = account
        contentShown = false
        rows = []
        rowsByID = [:]
        collectionView.layer.removeAllAnimations()
        collectionView.layer.opacity = 1
        applySnapshot(reconfigure: false)
        collectionView.contentOffset = CGPoint(x: 0, y: -collectionView.contentInset.top)
        load()
    }

    /// 返回：内容快速淡出，不再接收触摸
    func close() {
        loadTask?.cancel()
        loadTask = nil
        stopScrolling()
        collectionView.isUserInteractionEnabled = false
        collectionView.scrollsToTop = false
        collectionView.accessibilityElementsHidden = true
        CardMotion.setOpacity(collectionView.layer, 0, timing: .easeIn(0.15))
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
        collectionView.layer.removeAllAnimations()
        collectionView.layer.opacity = 1
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
            // 已经显示的行内容可能变了（备注、状态、余额），重新配置；新出现的行本来就会配置
            let shown = Set(dataSource.snapshot().itemIdentifiers)
            snapshot.reconfigureItems(snapshot.itemIdentifiers.filter { shown.contains($0) })
        }
        dataSource.apply(snapshot, animatingDifferences: false)
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
