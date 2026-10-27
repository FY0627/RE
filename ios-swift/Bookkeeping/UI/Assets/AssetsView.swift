import SwiftUI
import BKModel
import BKBackend

/// 滚动位置和标题区高度。普通 class，不是 @Observable：滚动时写入不会触发重新渲染，只在点按卡片时读取。
final class AssetsScrollBox {
    var scrollOffset: CGFloat = 0
    var headerHeight: CGFloat = 0
    var pageSize: CGSize = .zero
    /// 详情的滚动距离；关闭详情时用它算出卡片当前在哪
    var detailOffset: CGFloat = 0
}

/// 资产页：卡包 → 点按卡片展开详情 → 返回。最下方是灰色的「已停用」卡包，也可以点开查看详情。
///
/// 转场参考 Apple 钱包：选中的卡片移到顶部；它上面的卡一边上移一边缩小、向里倾斜，收到选中卡片后面；
/// 它下面的卡同时向下落出屏幕；详情内容跟在卡片下面升起、淡入。返回时内容先淡出，卡片回到原位，
/// 下面的卡同时升回来，像原来一样压住它的下半部分。
///
/// 选中的卡和它下面的卡在卡包和详情里各有一份，两份从同一帧开始走同样的动画，位置始终相同，只切换显示哪一份（`cardInDetail`）：
/// - 打开：详情先不带动画出现在卡包上层，卡片画在它们在卡包里的位置（看不出变化），下一帧选中的卡移到顶部、
///   下面的卡落下、内容跟着升起。选中的卡和内容在同一个滚动区，点开马上就能滚动；下面的卡叠在选中的卡和内容上层，
///   和卡包里一样压住选中卡的下半部分，不用遮罩；
/// - 关闭：卡片一开始就交回卡包，由卡包里的卡从当前位置（详情滚动过就更靠上）回到原位；详情移到卡包下层，只剩内容淡出。
///   卡包马上能滑动、能点；返回途中再点同一张卡会转向重新打开（卡包没滑动过时两份仍同步，直接交回详情），
///   点别的卡或卡包已滑动时，先在卡包里转向打开，停稳后再交给详情。
/// 性能做法（参考 Apple 关于 SwiftUI 动画与渲染卡顿的建议）：
/// - 打开 / 关闭只改一个状态（选中的卡），放在一个弹簧动画事务里；所有卡片按新状态一次算出终点，
///   动画只插值 offset / scaleEffect / rotation3DEffect / opacity 这些渲染变换，不重新布局、不每帧执行 body；
/// - 卡片在卡包和详情里尺寸相同，转场中不改变 frame；
/// - 滚动时不逐卡记录位置，只记录一个滚动偏移，点按时算出卡片要移动的距离；
/// - 弹簧动画可以被打断并平滑转向，动画中途再点也不会跳帧。
struct AssetsView: View {
    let openAddAccount: () -> Void

    @Environment(LedgerStore.self) private var store
    @Environment(DetailMotionState.self) private var motion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var box = AssetsScrollBox()
    /// 详情显示的卡。和选中的卡分开：关闭动画结束后才移除，在这之前内容在卡包下层淡出
    @State private var detailAccountID: String?
    /// 每次新建详情 +1，作为详情的标识
    @State private var detailSession = 0
    /// 选中的卡和下面的卡画在详情里（卡包里那几张隐藏）；为 false 时由卡包里的卡显示，详情在卡包下层
    @State private var cardInDetail = false
    /// 详情里的卡片相对顶部位置的位移：打开后为 0，打开前 / 关闭后是它在卡包里的位置
    @State private var detailLift: CGFloat = 0
    /// 下面的卡是否已落出屏幕（详情里那份按它定位）
    @State private var belowDropped = false
    /// 卡片不在详情里时详情不能滚动，卡片和内容才能对齐
    @State private var scrollLocked = false
    /// 开始关闭时卡包的滚动位置；返回途中卡包没滑动过，详情里的卡才和卡包里的同步，可以直接重新打开
    @State private var closeStackOffset: CGFloat?
    /// 详情的内容（卡片下面的部分）是否显示
    @State private var contentShown = false
    /// 每次打开 / 关闭 +1；动画完成回调据此判断自己是否已经过时
    @State private var motionToken = 0
    /// 卡包第一张卡从当前位置移到详情位置所需的位移；点按时计算一次
    @State private var openShift: CGFloat = 0
    /// 关闭时详情已滚动的距离：卡包里的卡按这个距离上移，和详情里的卡对齐
    @State private var scrollShift: CGFloat = 0
    /// 下面的卡落下的距离：页面高度；卡包顶端已滚出屏幕时再加上滚出的部分，保证落到屏幕外
    @State private var dropDistance: CGFloat = 0
    /// 最近一次打开的卡在卡包里的位置；关闭后保留，用来让原来在下面的卡晚一点升回来
    @State private var openedIndex: Int?
    @State private var cardPendingCount = 0
    @State private var sheet: AssetsSheet?
    @Namespace private var glass

    private var selectedID: String? { motion.selectedAccountID }
    private var isOpen: Bool { selectedID != nil }

    enum AssetsSheet: Identifiable {
        case info, face, pending, manage
        var id: Self { self }
    }

    /// 卡包顺序：使用中的卡在前，已停用的卡在后
    private var stackAccounts: [Account] { store.accounts + store.archivedAccounts }

    var body: some View {
        GeometryReader { proxy in
            let cardHeight = AppLayout.cardHeight(proxy.size.width)
            let detailAccount = detailAccountID.flatMap { store.account(id: $0) }
            ZStack(alignment: .top) {
                stack(size: proxy.size)

                if let detailAccount {
                    // 不带转场：出现和移除都不带动画，动画只在详情里面的内容上
                    AccountDetailView(
                        account: detailAccount,
                        pendingCount: cardPendingCount,
                        cardTop: AppLayout.detailTop,
                        cardHeight: cardHeight,
                        cardLift: detailLift,
                        belowCards: belowCards(width: proxy.size.width),
                        showsCards: cardInDetail,
                        contentShown: contentShown,
                        scrollLocked: scrollLocked,
                        box: box,
                        openPending: { sheet = .pending },
                        close: close
                    )
                    .id(detailSession)
                    // 卡片交回卡包后（返回途中）详情移到卡包下层、不接收触摸，卡包马上能滑动、能点。
                    // 在卡包里转向打开、还没交接时详情虽在下层，也由它接收触摸（卡包这时不接收），内容一出现就能点
                    .zIndex(cardInDetail ? 0 : -1)
                    .allowsHitTesting(cardInDetail || isOpen)
                }

                topBar
                    .padding(.horizontal, AppLayout.cardInset)
                    .padding(.top, 2)
            }
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { box.pageSize = $0 }
        // 详情展开时标签栏隐藏；忽略底部安全区，避免标签栏显隐改变页面尺寸
        .ignoresSafeArea(.container, edges: .bottom)
        .background(Color(.systemGroupedBackground))
        // 按详情显示的卡加载：点按时就开始，尽量在内容升起前算好，「N 条账单待处理」不在入场途中插进来把余额往下推
        .task(id: PendingKey(account: detailAccountID, revision: store.revision)) { await loadPendingCount() }
        .onChange(of: stackAccounts.map(\.id)) { _, ids in
            // 详情里停用 / 启用后卡片换了位置：详情保持打开，按新位置重新区分上面和下面的卡
            guard let selectedID else { return }
            if let index = ids.firstIndex(of: selectedID) {
                openedIndex = index
            } else {
                motionToken += 1
                detailAccountID = nil
                cardInDetail = false
                scrollLocked = false
                motion.selectedAccountID = nil
            }
        }
        .sheet(item: $sheet) { sheet in
            if sheet == .manage {
                AccountManagerView()
            } else if let selectedID {
                switch sheet {
                case .info: CardInfoView(accountID: selectedID)
                case .face: CardFaceEditor(accountID: selectedID)
                default: PendingView(account: store.account(id: selectedID))
                }
            }
        }
    }

    // MARK: 卡包

    private func stack(size: CGSize) -> some View {
        let cardHeight = AppLayout.cardHeight(size.width)
        let accounts = stackAccounts
        let layout = stackLayout(width: size.width)
        return ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                header(count: store.accounts.count)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { box.headerHeight = $0 }

                // 两个卡包放在同一个 ZStack 里：打开任何一张卡时，其他卡都按同一套规则收到后面或落出屏幕
                if !accounts.isEmpty {
                    ZStack(alignment: .top) {
                        if layout.archived > 0 {
                            sectionTitle("已停用", count: layout.archived)
                                .frame(height: StackLayout.sectionTitleHeight, alignment: .bottom)
                                .offset(y: layout.archivedTitleY)
                                .fadesWhenOpen(isOpen)
                        }
                        ForEach(Array(accounts.enumerated()), id: \.element.id) { index, account in
                            card(account, index: index, height: cardHeight, restY: layout.restY(index))
                        }
                    }
                    .frame(height: layout.height, alignment: .top)
                }
                // 标签栏下方留白（页面忽略了底部安全区）
                Color.clear.frame(height: 120)
            }
            .padding(.horizontal, AppLayout.cardInset)
        }
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y + $0.contentInsets.top } action: { _, offset in
            box.scrollOffset = offset
        }
        .scrollDisabled(isOpen)
        .scrollIndicators(.hidden)
        // 详情打开时卡包完全不接收触摸：卡包里隐藏的选中卡停在顶部，详情滚动后流水正好在它的位置，
        // 点流水时会同时点到它，既打开流水详情又返回卡包
        .allowsHitTesting(!isOpen && !cardInDetail)
    }

    /// 「资产」标题、净资产卡、「银行卡」一行（没有使用中的卡时是添加卡片的占位）。打开详情时向上淡出，返回时在卡片回位后淡入。
    private func header(count: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("资产")
                .font(.largeTitle.weight(.bold))
                .frame(height: 44)
                .padding(.horizontal, 4)
                .padding(.top, 2)
                .accessibilityAddTraits(.isHeader)

            OverviewCard()
                .padding(.top, 8)

            if count > 0 {
                sectionTitle("银行卡", count: count)
            } else {
                EmptyWalletCard(action: openAddAccount)
                    .padding(.top, 24)
                    .padding(.bottom, 10)
            }
        }
        .fadesWhenOpen(isOpen)
    }

    private func sectionTitle(_ title: String, count: Int) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.title3.weight(.semibold))
            Spacer()
            Text("共 \(count) 张").font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
        .padding(.top, 24)
        .padding(.bottom, 10)
    }

    private func card(_ account: Account, index: Int, height: CGFloat, restY: CGFloat) -> some View {
        let role: CardRole
        if selectedID == nil {
            role = .resting
        } else if selectedID == account.id {
            role = .selected
        } else {
            role = index < (openedIndex ?? 0) ? .behind : .below
        }
        return WalletCardView(
            account: account,
            balanceText: store.balances[account.id]?.cardText ?? "余额未知"
        )
        .grayscale(account.archived ? 1 : 0)
        .frame(height: height)
        // 选中的卡和下面的卡画在详情里时，卡包里这几张隐藏（不带动画，见 open() / animateClose()）。
        // 只看 cardInDetail 和 openedIndex：切换显示的那一帧它们不带动画，不会跟着转场的动画淡入淡出
        .opacity(cardInDetail && index >= (openedIndex ?? .max) ? 0 : 1)
        // 点按区域要放在位移之前，才会跟着卡片移动；放在之后时所有卡的点按区域都叠在卡包顶部，总是点到最上面那张
        .contentShape(Rectangle())
        .onTapGesture {
            if role == .selected { close() } else { open(account) }
        }
        .modifier(CardPlacement(
            role: role,
            restY: restY,
            openY: openShift,
            scrollShift: scrollShift,
            dropDistance: dropDistance,
            wasBelow: index > (openedIndex ?? .max),
            reduceMotion: reduceMotion
        ))
        .allowsHitTesting(role == .resting || role == .selected)
        .accessibilityHidden(role == .behind || role == .below)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(role == .selected ? "返回卡包" : account.archived ? "已停用，打开账户详情" : "打开账户详情")
    }

    // MARK: 顶部按钮

    /// 左侧返回按钮随详情一起出现。右侧卡包状态是「+」和「更多」合成的玻璃胶囊；
    /// 打开详情时「+」从胶囊里收起（液态玻璃的合并动画），剩下的按钮变成详情菜单。
    private var topBar: some View {
        HStack {
            if isOpen {
                Button(action: close) {
                    ToolbarIcon("chevron.left")
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: Circle())
                .accessibilityLabel("返回卡包")
                .transition(.opacity.combined(with: .scale(scale: 0.6)))
            }
            Spacer()
            GlassEffectContainer {
                HStack(spacing: 0) {
                    if !isOpen {
                        Button(action: openAddAccount) {
                            ToolbarIcon("plus")
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("添加银行卡")
                        .glassEffect(.regular.interactive(), in: Capsule())
                        .glassEffectUnion(id: "actions", namespace: glass)
                        .glassEffectID("add", in: glass)
                    }
                    moreButton
                        .glassEffect(.regular.interactive(), in: Capsule())
                        .glassEffectUnion(id: "actions", namespace: glass)
                        .glassEffectID("more", in: glass)
                }
            }
        }
    }

    /// 卡包状态：管理银行卡（启用 / 停用）；详情状态：这张卡的菜单。
    ///
    /// 始终是同一个 Menu，图标不变；卡包状态在上面盖一层透明按钮直接打开「管理银行卡」。
    /// 如果两种状态用两个不同的视图，切换时图标会交叉淡入淡出，看起来闪一下。
    private var moreButton: some View {
        Menu {
            Button("卡片信息", systemImage: "creditcard") { sheet = .info }
            Button("编辑卡面", systemImage: "paintbrush") { sheet = .face }
            Button(cardPendingCount > 0 ? "待处理账单（\(cardPendingCount)）" : "待处理账单", systemImage: "tray") { sheet = .pending }
        } label: {
            ToolbarIcon("ellipsis")
        }
        .tint(Color.primary)
        .overlay {
            if !isOpen {
                Button { sheet = .manage } label: {
                    Color.clear.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .accessibilityLabel(isOpen ? "更多" : "管理银行卡")
    }

    // MARK: 转场

    private var transition: Animation { DetailMotionState.transition(reduceMotion: reduceMotion) }

    /// 详情内容在卡片上移的同时跟在它下面升起、淡入，整体一起出现
    private var contentEntrance: Animation {
        reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.5, dampingFraction: 1).delay(0.08)
    }

    /// 返回时内容先快速淡出，卡片同时开始回卡包
    private var contentExit: Animation { .easeIn(duration: 0.15) }

    private func stackLayout(width: CGFloat) -> StackLayout {
        StackLayout(
            active: store.accounts.count,
            archived: store.archivedAccounts.count,
            cardHeight: AppLayout.cardHeight(width),
            peek: AppLayout.peek(width)
        )
    }

    /// 卡片在卡包里的位置相对详情顶部位置的距离（不算详情的滚动）
    private func restLift(_ index: Int) -> CGFloat {
        stackLayout(width: box.pageSize.width).restY(index) - (openShift - scrollShift)
    }

    /// 详情里画的下面那几张卡，位置相对详情里卡片的顶部位置。
    /// 卡包打开时不能滚动，下面的卡只按 dropDistance 落下 / 升起，不受 scrollShift 影响
    private func belowCards(width: CGFloat) -> [AccountDetailView.BelowCard] {
        guard let index = openedIndex else { return [] }
        let layout = stackLayout(width: width)
        let accounts = stackAccounts
        return accounts.indices.dropFirst(index + 1).map { i in
            .init(account: accounts[i], lift: layout.restY(i) - openShift + (belowDropped ? dropDistance : 0))
        }
    }

    /// 详情里下面的卡的动画，和卡包里那几张（CardPlacement）完全相同，两份才始终对齐
    private var belowDrop: Animation { reduceMotion ? transition : CardPlacement.drop }
    private var belowRise: Animation { reduceMotion ? transition : CardPlacement.rise }

    private func open(_ account: Account) {
        guard selectedID == nil, let index = stackAccounts.firstIndex(where: { $0.id == account.id }) else { return }
        if detailAccountID == account.id, index == openedIndex, closeStackOffset == box.scrollOffset {
            // 返回途中再点同一张卡，卡包没滑动过：详情里的卡一直和卡包里的同步，直接交回详情、从当前位置转向打开
            withoutAnimation {
                cardInDetail = true
                scrollLocked = false
            }
            animateOpen(account.id)
            return
        }
        let reopening = detailAccountID != nil
        // 卡包顶端当前在屏幕上的位置 = 标题区高度 - 滚动偏移；移到详情位置所需的位移对每张卡都相同
        let stackTop = box.headerHeight - box.scrollOffset
        openShift = AppLayout.detailTop - stackTop
        scrollShift = 0
        dropDistance = box.pageSize.height + max(0, -stackTop)
        openedIndex = index
        box.detailOffset = 0
        motionToken += 1
        let token = motionToken
        withoutAnimation {
            detailSession += 1
            detailAccountID = account.id
            contentShown = false
            if reopening {
                // 返回动画还没结束，卡包里的卡还在动：先由卡包里的卡转向打开，详情里那份直接放在终点，停稳后再交接
                cardInDetail = false
                detailLift = 0
                belowDropped = true
                scrollLocked = true
            } else {
                // 详情不带动画出现，卡片画在它们在卡包里的位置，卡包里那几张同时隐藏，看不出变化
                cardInDetail = true
                detailLift = restLift(index)
                belowDropped = false
                scrollLocked = false
            }
        }
        // 下一帧（详情已经画出来）再开始转场，卡片和内容才有起点可以动画
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(10))
            guard token == motionToken else { return }
            if reopening {
                animateOpenInStack(account.id)
            } else {
                animateOpen(account.id)
            }
        }
    }

    private func animateOpen(_ id: String) {
        motionToken += 1
        let signpost = AppServices.signposter.beginInterval("DetailOpen")
        // 卡包里的卡按新状态一起动：上面的卡收到后面，下面的卡落出屏幕；详情里那份走同样的动画
        withAnimation(transition) {
            motion.selectedAccountID = id
            detailLift = 0
        } completion: {
            AppServices.signposter.endInterval("DetailOpen", signpost)
        }
        withAnimation(belowDrop) { belowDropped = true }
        // 内容在卡片移动的同时入场
        withAnimation(contentEntrance) { contentShown = true }
    }

    /// 卡包里的卡从当前位置转向打开；停稳后交给详情，之后才能滚动
    private func animateOpenInStack(_ id: String) {
        motionToken += 1
        let token = motionToken
        let signpost = AppServices.signposter.beginInterval("DetailOpen")
        withAnimation(transition, completionCriteria: .removed) {
            motion.selectedAccountID = id
        } completion: {
            AppServices.signposter.endInterval("DetailOpen", signpost)
            guard token == motionToken else { return }
            withoutAnimation {
                cardInDetail = true
                scrollLocked = false
            }
        }
        withAnimation(contentEntrance) { contentShown = true }
    }

    private func close() {
        guard selectedID != nil else { return }
        motionToken += 1
        let token = motionToken
        scrollLocked = true
        // 往下拉时详情里的卡不动，按没滚动算
        let scrolled = max(0, box.detailOffset)
        guard cardInDetail, scrolled != scrollShift else {
            animateClose(token)
            return
        }
        // 详情滚动过：卡包里隐藏的卡（选中的卡和收在后面的卡）先不带动画上移到卡片现在的位置，下一帧再交回卡包。
        // scrollShift 是单独的一层位移，不打断还在进行的打开动画
        withoutAnimation { scrollShift = scrolled }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(10))
            guard token == motionToken else { return }
            animateClose(token)
        }
    }

    private func animateClose(_ token: Int) {
        guard let index = openedIndex else { return }
        let signpost = AppServices.signposter.beginInterval("DetailClose")
        // 卡片在详情里时两份同步；在卡包里转向打开、还没交接时详情里那份停在终点，不同步，不能直接重新打开
        closeStackOffset = cardInDetail ? box.scrollOffset : nil
        // 交回卡包：卡包里的卡和详情里的位置相同，接着从当前位置动；详情移到卡包下层，卡包马上能滑动、能点
        withoutAnimation { cardInDetail = false }
        withAnimation(contentExit) { contentShown = false }
        // 详情里隐藏的那份也走同样的动画，返回途中再点同一张卡时可以直接交回详情
        withAnimation(belowRise) { belowDropped = false }
        // 卡片已在卡包里，详情只剩淡出的内容，看起来停稳（不必等弹簧完全静止）就移除；
        // 之后再点卡片走普通的打开，马上能点、能滑
        withAnimation(transition, completionCriteria: .logicallyComplete) {
            motion.selectedAccountID = nil
            detailLift = restLift(index)
        } completion: {
            AppServices.signposter.endInterval("DetailClose", signpost)
            guard token == motionToken else { return }
            withoutAnimation {
                detailAccountID = nil
                scrollLocked = false
            }
        }
    }

    private func withoutAnimation(_ body: () -> Void) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction, body)
    }

    private struct PendingKey: Hashable {
        let account: String?
        let revision: Int
    }

    private func loadPendingCount() async {
        guard let detailAccountID, let account = store.account(id: detailAccountID), store.pendingCount > 0 else {
            cardPendingCount = 0
            return
        }
        cardPendingCount = await store.pendingItems().filter { PendingView.belongs($0, to: account) }.count
    }
}

// MARK: - 卡片位置

/// 卡包里每张卡静止时的位置：使用中的卡从顶端开始叠放；已停用的卡在下面，中间隔一行「已停用」标题。
private struct StackLayout {
    let active: Int
    let archived: Int
    let cardHeight: CGFloat
    let peek: CGFloat

    static let sectionTitleHeight: CGFloat = 64

    private func pileHeight(_ count: Int) -> CGFloat {
        count > 0 ? cardHeight + CGFloat(count - 1) * peek : 0
    }

    var archivedTitleY: CGFloat { pileHeight(active) }
    private var archivedTop: CGFloat { archivedTitleY + Self.sectionTitleHeight }

    func restY(_ index: Int) -> CGFloat {
        index < active ? CGFloat(index) * peek : archivedTop + CGFloat(index - active) * peek
    }

    var height: CGFloat { archived > 0 ? archivedTop + pileHeight(archived) : pileHeight(active) }
}

private extension View {
    /// 标题区随详情打开向上淡出，返回时在卡片回位后淡入
    func fadesWhenOpen(_ isOpen: Bool) -> some View {
        self
            .offset(y: isOpen ? -32 : 0)
            .animation(isOpen ? .easeOut(duration: 0.18) : .easeIn(duration: 0.2).delay(0.18)) {
                $0.opacity(isOpen ? 0 : 1)
            }
            .allowsHitTesting(!isOpen)
            .accessibilityHidden(isOpen)
    }
}

private enum CardRole {
    /// 卡包里按顺序叠放
    case resting
    /// 选中的卡：移到详情位置
    case selected
    /// 选中卡上面的卡：移到选中卡后面，缩小并向里倾斜，最后隐藏
    case behind
    /// 选中卡下面的卡：直接向下落出屏幕
    case below
}

/// 只使用渲染变换：位移、缩放、3D 旋转、透明度。这些属性的动画由 SwiftUI 直接插值，不触发布局。
private struct CardPlacement: ViewModifier {
    let role: CardRole
    let restY: CGFloat
    let openY: CGFloat
    /// 关闭时详情已滚动的距离；选中的卡和收在后面的卡按它上移。单独一层位移，设置它不会打断还在进行的转场动画
    let scrollShift: CGFloat
    /// 下面的卡落出屏幕的距离
    let dropDistance: CGFloat
    /// 刚关闭的详情打开时，这张卡在选中卡下面
    let wasBelow: Bool
    let reduceMotion: Bool

    /// 收到后面时的缩放和倾斜角度
    static let behindScale: CGFloat = 0.86
    static let behindTilt: Double = 30
    /// 下面的卡落下的时长；落出屏幕后不再绘制
    static let dropDuration: Double = 0.25
    /// 下面的卡落出屏幕：加速下落
    static let drop: Animation = .easeIn(duration: dropDuration)
    /// 返回时下面的卡升回来：和选中的卡同样的弹簧，稍晚一点，让详情内容先开始淡出
    static var rise: Animation { DetailMotionState.transition(reduceMotion: false).delay(0.06) }

    private var y: CGFloat {
        switch role {
        case .resting: restY
        case .selected, .behind: openY
        case .below: restY + dropDistance
        }
    }

    /// 下面的卡单独用「加速下落」；返回时和选中的卡一起升回来，稍晚一点，让详情内容先开始淡出。
    /// 其余情况沿用转场的弹簧动画。
    private var offsetAnimation: Animation? {
        guard !reduceMotion else { return nil }
        if role == .below { return Self.drop }
        if role == .resting, wasBelow { return Self.rise }
        return nil
    }

    func body(content: Content) -> some View {
        let behind = role == .behind && !reduceMotion
        let animation = offsetAnimation
        content
            .scaleEffect(behind ? Self.behindScale : 1)
            .rotation3DEffect(.degrees(behind ? Self.behindTilt : 0), axis: (x: 1, y: 0, z: 0), anchor: .center, perspective: 0.6)
            .offset(y: y)
            .offset(y: role == .selected || role == .behind ? -scrollShift : 0)
            // 只替换有动画的事务（打开 / 关闭）；滚动、数据刷新等没有动画的更新保持原样
            .transaction { transaction in
                if let animation, transaction.animation != nil { transaction.animation = animation }
            }
            // 打开时先收到后面，末段再淡出（这时已被选中的卡挡住，淡出后不再参与绘制）；返回时立即淡入
            .animation(role == .behind ? .easeIn(duration: 0.15).delay(0.25) : .easeOut(duration: 0.1)) {
                $0.opacity(role == .behind ? 0 : 1)
            }
            // 不调整层级：按卡包顺序叠放，上面的卡在选中卡后面，下面的卡在选中卡上层，和钱包一样
    }
}

// MARK: - 总览与空状态

/// 净资产卡：只显示净资产、总资产、总负债；点按卡片查看各币种明细。
///
/// 有汇率时（由快捷指令导入）所有币种换算成主要币种合计；
/// 否则只显示主要币种的金额，其他币种在明细里。
/// 每张卡每个币种取推算余额（从初始余额起算，没填初始余额的不计入）；正数计入总资产，负数（欠款）计入总负债。
private struct OverviewCard: View {
    @Environment(LedgerStore.self) private var store
    @Environment(ExchangeRateStore.self) private var rates
    @AppStorage(ExchangeRateStore.primaryKey) private var primaryCode = CurrencyCode.cny.rawValue
    @State private var showDetail = false

    var body: some View {
        let summary = NetWorth(store: store, rates: rates.rates, primary: CurrencyCode(primaryCode))
        let main = summary.main
        VStack(alignment: .leading, spacing: 0) {
            Text("净资产").font(.subheadline).foregroundStyle(.secondary)
            Text(Fmt.money(main.net, main.currency))
                .font(.system(.largeTitle, design: .rounded).weight(.bold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.top, 2)
            HStack(spacing: 0) {
                figure("总资产", Fmt.money(main.assets, main.currency))
                figure("总负债", Fmt.money(main.liabilities, main.currency))
            }
            .padding(.top, 14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .onTapGesture { showDetail = true }
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("查看各币种明细")
        .sheet(isPresented: $showDetail) { NetWorthDetailView() }
    }

    private func figure(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.footnote).foregroundStyle(.secondary)
            Text(value).font(.headline).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// 净资产明细：合计（有汇率时为换算后的金额）、各币种的原币金额、汇率来源。
private struct NetWorthDetailView: View {
    @Environment(LedgerStore.self) private var store
    @Environment(ExchangeRateStore.self) private var rates
    @Environment(\.dismiss) private var dismiss
    @AppStorage(ExchangeRateStore.primaryKey) private var primaryCode = CurrencyCode.cny.rawValue

    var body: some View {
        let summary = NetWorth(store: store, rates: rates.rates, primary: CurrencyCode(primaryCode))
        NavigationStack {
            List {
                Section(summary.converted == nil ? summary.main.currency.chineseName : "合计（\(summary.main.currency.chineseName)）") {
                    totalsRows(summary.main)
                }
                if !summary.totals.isEmpty {
                    Section("各币种") {
                        ForEach(summary.totals, id: \.currency) { t in
                            let skipped = summary.converted?.skipped.contains(t.currency) == true
                            VStack(alignment: .leading, spacing: 6) {
                                LabeledContent(t.currency.chineseName) {
                                    Text(skipped ? "无汇率" : amount(t.net, t.currency)).monospacedDigit()
                                }
                                .font(.headline)
                                if !skipped {
                                    LabeledContent("资产", value: amount(t.assets, t.currency))
                                    LabeledContent("负债", value: amount(t.liabilities, t.currency))
                                }
                            }
                            .monospacedDigit()
                        }
                    }
                }
                if let current = rates.rates {
                    Section("汇率") {
                        LabeledContent("更新时间", value: Fmt.dateTime(current.updatedAt))
                        Link(ExchangeRateFeed.attribution, destination: ExchangeRateFeed.attributionURL)
                    }
                }
            }
            .navigationTitle("净资产")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成", systemImage: "checkmark") { dismiss() } }
            }
        }
    }

    @ViewBuilder
    private func totalsRows(_ t: NetWorth.Totals) -> some View {
        LabeledContent("净资产", value: amount(t.net, t.currency))
        LabeledContent("总资产", value: amount(t.assets, t.currency))
        LabeledContent("总负债", value: amount(t.liabilities, t.currency))
    }

    private func amount(_ minor: Int64, _ currency: CurrencyCode) -> String {
        Fmt.money(minor, currency)
    }
}

/// 净资产的计算：按币种汇总各卡的推算余额，有汇率时换算成主要币种合计。
private struct NetWorth {
    struct Totals {
        var currency: CurrencyCode
        var assets: Int64 = 0
        var liabilities: Int64 = 0
        var cards = 0
        var net: Int64 { assets - liabilities }
    }

    struct Converted {
        var total: Totals
        var skipped: Set<CurrencyCode>
    }

    /// 每个币种一项：主要币种在前，其余按有余额的卡多少、金额大小排序
    let totals: [Totals]
    /// 有汇率时的换算结果
    let converted: Converted?
    /// 卡片上显示的合计：换算后的金额，或者主要币种的金额
    let main: Totals

    @MainActor
    init(store: LedgerStore, rates: ExchangeRates?, primary: CurrencyCode) {
        let totals = Self.totals(store.accounts, store.balances, primary: primary)
        let converted = rates.flatMap { Self.convert(totals, to: primary, with: $0) }
        self.totals = totals
        self.converted = converted
        self.main = converted?.total ?? totals.first(where: { $0.currency == primary }) ?? Totals(currency: primary)
    }

    static func totals(_ accounts: [Account], _ balances: [String: AccountBalances], primary: CurrencyCode) -> [Totals] {
        var byCurrency: [CurrencyCode: Totals] = [:]
        for account in accounts {
            for item in balances[account.id]?.items ?? [] {
                guard let amount = item.ledgerDerivedMinor else { continue }
                var entry = byCurrency[item.currency] ?? Totals(currency: item.currency)
                if amount >= 0 { entry.assets += amount } else { entry.liabilities += -amount }
                entry.cards += 1
                byCurrency[item.currency] = entry
            }
        }
        return byCurrency.values.sorted { a, b in
            if (a.currency == primary) != (b.currency == primary) { return a.currency == primary }
            if a.cards != b.cards { return a.cards > b.cards }
            let sizeA = a.assets + a.liabilities, sizeB = b.assets + b.liabilities
            if sizeA != sizeB { return sizeA > sizeB }
            return a.currency < b.currency
        }
    }

    /// 资产和负债分别换算后相加；缺汇率的币种不计入。
    static func convert(_ totals: [Totals], to primary: CurrencyCode, with rates: ExchangeRates) -> Converted? {
        guard rates.rate(primary) != nil else { return nil }
        var sum = Totals(currency: primary)
        var skipped: Set<CurrencyCode> = []
        for t in totals {
            guard let assets = rates.convert(t.assets, from: t.currency, to: primary),
                  let liabilities = rates.convert(t.liabilities, from: t.currency, to: primary) else {
                skipped.insert(t.currency)
                continue
            }
            sum.assets += assets
            sum.liabilities += liabilities
            sum.cards += t.cards
        }
        return Converted(total: sum, skipped: skipped)
    }
}

private struct EmptyWalletCard: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: "creditcard.and.123").font(.largeTitle).foregroundStyle(.secondary)
                Text("添加银行卡").font(.headline)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
            .background(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
