import SwiftUI
import BKModel

/// 滚动位置和标题区高度。普通 class，不是 @Observable：滚动时写入不会触发重新渲染，只在点按卡片时读取。
final class AssetsScrollBox {
    var scrollOffset: CGFloat = 0
    var headerHeight: CGFloat = 0
}

/// 资产页：卡包 → 点按卡片展开详情 → 返回。
///
/// 转场参考 Apple 钱包：选中的卡片移到顶部；其余卡片一边上移一边缩小、向里倾斜，收到选中卡片后面。
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
    /// 卡包第一张卡从当前位置移到详情位置所需的位移；点按时计算一次
    @State private var openShift: CGFloat = 0
    @State private var hideBalance = false
    @State private var cardPendingCount = 0
    @State private var detailSheet: DetailSheet?

    private var selectedID: String? { motion.selectedAccountID }
    private var isOpen: Bool { selectedID != nil }

    enum DetailSheet: Identifiable {
        case info, face, pending
        var id: Self { self }
    }

    var body: some View {
        GeometryReader { proxy in
            let cardHeight = AppLayout.cardHeight(proxy.size.width)
            let selected = selectedID.flatMap { store.account(id: $0) }
            ZStack(alignment: .top) {
                stack(width: proxy.size.width)

                if let selected {
                    AccountDetailView(
                        account: selected,
                        hideBalance: hideBalance,
                        pendingCount: cardPendingCount,
                        openPending: { detailSheet = .pending },
                        close: close
                    )
                    .padding(.top, AppLayout.detailTop + cardHeight + 8)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .offset(y: 48)),
                        removal: .opacity.animation(.easeOut(duration: 0.15))
                    ))
                }

                topBar
                    .padding(.horizontal, AppLayout.cardInset)
                    .padding(.top, 2)
            }
        }
        // 详情展开时标签栏隐藏；忽略底部安全区，避免标签栏显隐改变页面尺寸
        .ignoresSafeArea(.container, edges: .bottom)
        .background(Color(.systemGroupedBackground))
        .task(id: PendingKey(account: selectedID, revision: store.revision)) { await loadPendingCount() }
        .onChange(of: store.accounts.map(\.id)) { _, ids in
            // 卡片被隐藏后关闭详情
            if let selectedID, !ids.contains(selectedID) { motion.selectedAccountID = nil }
        }
        .sheet(item: $detailSheet) { sheet in
            if let selectedID {
                switch sheet {
                case .info:
                    CardInfoView(accountID: selectedID) {
                        close()
                        Task { await store.setArchived(accountID: selectedID, archived: true) }
                    }
                case .face:
                    CardFaceEditor(accountID: selectedID)
                case .pending:
                    PendingView(account: store.account(id: selectedID))
                }
            }
        }
    }

    // MARK: 卡包

    private func stack(width: CGFloat) -> some View {
        let cardHeight = AppLayout.cardHeight(width)
        let peek = AppLayout.peek(width)
        let accounts = store.accounts
        return ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                header(count: accounts.count)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { box.headerHeight = $0 }

                if accounts.isEmpty {
                    EmptyWalletCard(action: openAddAccount)
                } else {
                    ZStack(alignment: .top) {
                        ForEach(Array(accounts.enumerated()), id: \.element.id) { index, account in
                            card(account, index: index, height: cardHeight, peek: peek)
                        }
                    }
                    .frame(height: cardHeight + CGFloat(accounts.count - 1) * peek, alignment: .top)
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
    }

    /// 「资产」标题、净资产卡、「银行卡」一行。打开详情时向上淡出，返回时在卡片回位后淡入。
    private func header(count: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("资产")
                .font(.largeTitle.weight(.bold))
                .frame(height: 44)
                .padding(.horizontal, 4)
                .padding(.top, 2)
                .accessibilityAddTraits(.isHeader)

            OverviewCard(hideBalance: $hideBalance)
                .padding(.top, 8)

            HStack(alignment: .firstTextBaseline) {
                Text("银行卡").font(.title3.weight(.semibold))
                Spacer()
                Text("共 \(count) 张").font(.subheadline).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
            .padding(.top, 24)
            .padding(.bottom, 10)
        }
        .offset(y: isOpen ? -32 : 0)
        .animation(isOpen ? .easeOut(duration: 0.18) : .easeIn(duration: 0.2).delay(0.18)) {
            $0.opacity(isOpen ? 0 : 1)
        }
        .allowsHitTesting(!isOpen)
        .accessibilityHidden(isOpen)
    }

    private func card(_ account: Account, index: Int, height: CGFloat, peek: CGFloat) -> some View {
        let role: CardRole = selectedID == nil ? .resting : (selectedID == account.id ? .selected : .behind)
        return WalletCardView(
            account: account,
            balanceText: store.balances[account.id]?.cardText ?? "余额未知",
            hideBalance: hideBalance
        )
        .frame(height: height)
        // 点按区域要放在位移之前，才会跟着卡片移动；放在之后时所有卡的点按区域都叠在卡包顶部，总是点到最上面那张
        .contentShape(Rectangle())
        .onTapGesture {
            if role == .selected { close() } else { open(account) }
        }
        .modifier(CardPlacement(role: role, restY: CGFloat(index) * peek, openY: openShift, reduceMotion: reduceMotion))
        .allowsHitTesting(role != .behind)
        .accessibilityHidden(role == .behind)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(role == .selected ? "返回卡包" : "打开账户详情")
    }

    // MARK: 顶部按钮

    /// 左侧返回按钮随详情一起出现；右侧是同一个玻璃圆形按钮，图标直接在「+」和「更多」之间切换。
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
            Group {
                if isOpen {
                    Menu {
                        Button("卡片信息", systemImage: "creditcard") { detailSheet = .info }
                        Button("编辑卡面", systemImage: "paintbrush") { detailSheet = .face }
                        Button(cardPendingCount > 0 ? "待处理账单（\(cardPendingCount)）" : "待处理账单", systemImage: "tray") { detailSheet = .pending }
                    } label: {
                        ToolbarIcon("ellipsis")
                    }
                    .accessibilityLabel("更多")
                } else {
                    Button(action: openAddAccount) {
                        ToolbarIcon("plus")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("添加银行卡")
                }
            }
            .glassEffect(.regular.interactive(), in: Circle())
        }
    }

    // MARK: 转场

    private var transition: Animation {
        reduceMotion ? .easeInOut(duration: 0.25) : .spring(response: 0.5, dampingFraction: 0.86)
    }

    private func open(_ account: Account) {
        guard selectedID == nil else { return }
        // 第一张卡当前在屏幕上的位置 = 标题区高度 - 滚动偏移；移到详情位置所需的位移对每张卡都相同
        openShift = AppLayout.detailTop - (box.headerHeight - box.scrollOffset)
        let signpost = AppServices.signposter.beginInterval("DetailOpen")
        withAnimation(transition) {
            motion.selectedAccountID = account.id
        } completion: {
            AppServices.signposter.endInterval("DetailOpen", signpost)
        }
    }

    private func close() {
        guard selectedID != nil else { return }
        let signpost = AppServices.signposter.beginInterval("DetailClose")
        withAnimation(transition) {
            motion.selectedAccountID = nil
        } completion: {
            AppServices.signposter.endInterval("DetailClose", signpost)
        }
    }

    private struct PendingKey: Hashable {
        let account: String?
        let revision: Int
    }

    private func loadPendingCount() async {
        guard let selectedID, let account = store.account(id: selectedID), store.pendingCount > 0 else {
            cardPendingCount = 0
            return
        }
        cardPendingCount = await store.pendingItems().filter { PendingView.belongs($0, to: account) }.count
    }
}

// MARK: - 卡片位置

private enum CardRole {
    /// 卡包里按顺序叠放
    case resting
    /// 选中的卡：移到详情位置
    case selected
    /// 其他卡：移到选中卡后面，缩小并向里倾斜，最后隐藏
    case behind
}

/// 只使用渲染变换：位移、缩放、3D 旋转、透明度。这些属性的动画由 SwiftUI 直接插值，不触发布局。
private struct CardPlacement: ViewModifier {
    let role: CardRole
    let restY: CGFloat
    let openY: CGFloat
    let reduceMotion: Bool

    /// 收到后面时的缩放和倾斜角度
    static let behindScale: CGFloat = 0.86
    static let behindTilt: Double = 30

    func body(content: Content) -> some View {
        let behind = role == .behind && !reduceMotion
        content
            .scaleEffect(behind ? Self.behindScale : 1)
            .rotation3DEffect(.degrees(behind ? Self.behindTilt : 0), axis: (x: 1, y: 0, z: 0), anchor: .center, perspective: 0.6)
            .offset(y: role == .resting ? restY : openY)
            // 打开时先收到后面，末段再淡出（这时已被选中的卡挡住，淡出后不再参与绘制）；返回时立即淡入
            .animation(role == .behind ? .easeIn(duration: 0.15).delay(0.25) : .easeOut(duration: 0.1)) {
                $0.opacity(role == .behind ? 0 : 1)
            }
            .zIndex(role == .selected ? 1 : 0)
    }
}

// MARK: - 总览与空状态

/// 净资产卡，右上角是隐藏金额按钮。
///
/// - 打开「联网获取汇率」且有汇率时：所有币种按汇率换算成主要币种合计，下面列出各币种的原币金额；
/// - 否则：大字显示主要币种的净资产，其他币种各占一行，不做换算。
///
/// 每张卡每个币种取推算余额（银行通知余额或初始余额起算）；正数计入总资产，负数（欠款）计入总负债。
/// 信用卡通知里的「余额」含义因银行而异，只有填了初始余额的信用卡币种才计入。
private struct OverviewCard: View {
    @Binding var hideBalance: Bool
    @Environment(LedgerStore.self) private var store
    @Environment(ExchangeRateStore.self) private var rates
    @AppStorage(ExchangeRateStore.primaryKey) private var primaryCode = CurrencyCode.cny.rawValue
    @AppStorage(ExchangeRateStore.enabledKey) private var ratesEnabled = false

    var body: some View {
        let primary = CurrencyCode(primaryCode)
        let totals = Self.totals(store.accounts, store.balances, primary: primary)
        let converted = ratesEnabled ? rates.rates.flatMap { Self.convert(totals, to: primary, with: $0) } : nil
        let main = converted?.total ?? totals.first(where: { $0.currency == primary }) ?? Totals(currency: primary)
        let others = converted == nil ? totals.filter { $0.currency != primary } : totals
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("净资产").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Button {
                    hideBalance.toggle()
                } label: {
                    Image(systemName: hideBalance ? "eye.slash" : "eye")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, -12)
                .padding(.trailing, -10)
                .accessibilityLabel(hideBalance ? "显示金额" : "隐藏金额")
            }
            Text(amount(main.net, main.currency))
                .font(.system(.largeTitle, design: .rounded).weight(.bold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.top, 2)
            HStack(spacing: 0) {
                figure("总资产", amount(main.assets, main.currency))
                figure("总负债", amount(main.liabilities, main.currency))
            }
            .padding(.top, 14)

            if let note = note(converted: converted, totals: totals, primary: primary) {
                Text(note).font(.footnote).foregroundStyle(.secondary).padding(.top, 10)
            }

            if !others.isEmpty, converted == nil || totals.count > 1 || totals.first?.currency != primary {
                Divider().padding(.vertical, 12)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(others, id: \.currency) { other in
                        currencyRow(other, skipped: converted?.skipped.contains(other.currency) == true)
                    }
                }
            }
        }
        .padding(18)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private func note(converted: Converted?, totals: [Totals], primary: CurrencyCode) -> String? {
        if let converted {
            var text = "按汇率换算为\(primary.chineseName) · 汇率更新于 \(Fmt.dateTime(converted.updatedAt))"
            if !converted.skipped.isEmpty { text += " · 缺少汇率的币种未计入" }
            return text
        }
        guard totals.contains(where: { $0.currency != primary }) else { return nil }
        if ratesEnabled { return rates.isUpdating ? "正在获取汇率…" : "汇率暂不可用，其他币种分开列出" }
        return nil
    }

    private func amount(_ minor: Int64, _ currency: CurrencyCode) -> String {
        hideBalance ? "••••" : Fmt.money(minor, currency)
    }

    private func figure(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.footnote).foregroundStyle(.secondary)
            Text(value).font(.headline).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func currencyRow(_ t: Totals, skipped: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(t.currency.chineseName).font(.subheadline.weight(.medium))
                Spacer()
                Text(amount(t.net, t.currency)).font(.headline).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            }
            Text("资产 \(amount(t.assets, t.currency)) · 负债 \(amount(t.liabilities, t.currency))" + (skipped ? " · 无汇率，未计入合计" : ""))
                .font(.footnote).foregroundStyle(.secondary).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
        }
        .accessibilityElement(children: .combine)
    }

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
        var updatedAt: Date
    }

    /// 每个币种一项：主要币种在前，其余按有余额的卡多少、金额大小排序。
    static func totals(_ accounts: [Account], _ balances: [String: AccountBalances], primary: CurrencyCode) -> [Totals] {
        var byCurrency: [CurrencyCode: Totals] = [:]
        for account in accounts {
            for item in balances[account.id]?.items ?? [] {
                if account.cardType == .credit, item.base != .opening { continue }
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

    /// 资产和负债分别换算后相加；缺汇率的币种不计入并单独标出。
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
        return Converted(total: sum, skipped: skipped, updatedAt: rates.updatedAt)
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
