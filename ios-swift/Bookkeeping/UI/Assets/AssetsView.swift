import SwiftUI
import BKModel

/// 滚动和布局过程中的几何信息。普通 class，不是 @Observable：写入时不会触发重新渲染，
/// 只在点按卡片、关闭详情时读取一次。
final class AssetsGeometryBox {
    var cards: [String: CGRect] = [:]
    var overview: CGRect = .zero
    var detailScrollOffset: CGFloat = 0
}

/// 资产页：卡包堆叠 → 点按卡片飞到详情 → 返回（原型 `lib/pages/assets_page.dart`）。
struct AssetsView: View {
    let openPending: () -> Void
    let openAddAccount: () -> Void

    @Environment(LedgerStore.self) private var store
    @Environment(DetailMotionState.self) private var motion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var geometry = AssetsGeometryBox()
    @State private var selectedIndex: Int?
    @State private var source: CGRect = .zero
    @State private var destination: CGRect = .zero
    @State private var overviewSource: CGRect = .zero
    @State private var detailOpen = false
    @State private var hideBalance = false

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack(alignment: .topLeading) {
                stack(size: size)
                    .modifier(StackVisibility(progress: motion.progress, active: selectedIndex != nil))
                    .allowsHitTesting(selectedIndex == nil)
                    .accessibilityHidden(selectedIndex != nil)

                if let index = selectedIndex, store.accounts.indices.contains(index) {
                    let account = store.accounts[index]
                    if !detailOpen {
                        flyingCard(account: account, index: index, size: size)
                    }
                    AccountDetailView(
                        account: account,
                        progress: motion.progress,
                        isOpen: detailOpen,
                        viewport: size,
                        hideBalance: hideBalance,
                        geometry: geometry,
                        openPending: openPending,
                        close: closeDetail
                    )
                }
            }
            .coordinateSpace(.named("assets"))
        }
        // 详情展开时标签栏隐藏；忽略底部安全区，避免标签栏显隐改变页面尺寸、打断转场
        .ignoresSafeArea(.container, edges: .bottom)
        .background(Color(.systemGroupedBackground))
        .onChange(of: store.accounts.map(\.id)) { _, ids in
            // 卡片被隐藏后关闭详情
            if let index = selectedIndex, !ids.indices.contains(index) || motion.selectedAccountID != ids[index] {
                selectedIndex = nil
                detailOpen = false
                motion.selectedAccountID = nil
                motion.progress = 0
                motion.isAnimating = false
            }
        }
    }

    // MARK: 卡包

    private func stack(size: CGSize) -> some View {
        let cardHeight = AppLayout.stackedHeight(size.width)
        let peek = AppLayout.peek(size.width)
        let accounts = store.accounts
        let travelOffset = destination.minY - source.minY
        let exitDistance = size.height + 200
        let overviewExit = max(overviewSource.maxY + 24, abs(source.minY - AppLayout.detailTop))

        return ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                OverviewCard(hideBalance: $hideBalance)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("assets")) } action: { geometry.overview = $0 }
                    .modifier(OverviewExit(progress: motion.progress, distance: overviewExit, active: selectedIndex != nil))
                    .padding(.top, 12)

                HStack(alignment: .firstTextBaseline) {
                    Text("银行卡").font(.title3.weight(.semibold))
                    Spacer()
                    Text("共 \(accounts.count) 张").font(.subheadline).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 4)
                .padding(.top, 24)
                .padding(.bottom, 10)
                .modifier(OverviewExit(progress: motion.progress, distance: overviewExit, active: selectedIndex != nil))

                if accounts.isEmpty {
                    EmptyWalletCard(action: openAddAccount)
                } else {
                    LazyVStack(spacing: -(cardHeight - peek)) {
                        ForEach(Array(accounts.enumerated()), id: \.element.id) { index, account in
                            WalletCardView(
                                account: account,
                                balanceText: store.balances[account.id]?.cardText ?? "余额未知",
                                hideBalance: hideBalance,
                                height: cardHeight
                            )
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("assets")) } action: { geometry.cards[account.id] = $0 }
                            .modifier(StackCardMotion(
                                progress: motion.progress, index: index, selected: selectedIndex,
                                peek: peek, travelOffset: travelOffset, exitDistance: exitDistance
                            ))
                            .opacity(index == selectedIndex ? 0 : 1)
                            .contentShape(Rectangle())
                            .onTapGesture { openDetail(index: index, size: size) }
                            .accessibilityAddTraits(.isButton)
                            .accessibilityHint("打开账户详情")
                        }
                    }
                }
                // 标签栏下方留白（页面忽略了底部安全区）
                Color.clear.frame(height: 120)
            }
            .padding(.horizontal, AppLayout.cardInset)
        }
        .scrollDisabled(selectedIndex != nil)
        .scrollIndicators(.hidden)
    }

    private func flyingCard(account: Account, index: Int, size: CGSize) -> some View {
        let next = store.accounts.indices.contains(index + 1) ? store.accounts[index + 1] : nil
        let nextRest = next.flatMap { geometry.cards[$0.id] } ?? source.offsetBy(dx: 0, dy: AppLayout.peek(size.width))
        return FlightCard(
            progress: motion.progress,
            source: source,
            destination: destination,
            nextCard: next == nil ? nil : nextRest,
            exitDistance: size.height + 200,
            maskEnabled: PerfFlags.shared.flightMask
        ) { height, elevation in
            WalletCardView(
                account: account,
                balanceText: store.balances[account.id]?.cardText ?? "余额未知",
                hideBalance: hideBalance,
                height: height,
                elevation: elevation
            )
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: 转场

    private func openDetail(index: Int, size: CGSize) {
        guard selectedIndex == nil, !motion.isAnimating, store.accounts.indices.contains(index) else { return }
        let account = store.accounts[index]
        let width = AppLayout.cardWidth(size.width)
        source = geometry.cards[account.id] ?? CGRect(x: AppLayout.cardInset, y: 260, width: width, height: AppLayout.stackedHeight(size.width))
        overviewSource = geometry.overview
        destination = CGRect(x: AppLayout.cardInset, y: AppLayout.detailTop, width: width, height: AppLayout.detailHeight(size.width))
        geometry.detailScrollOffset = 0
        detailOpen = false
        selectedIndex = index
        withAnimation(.easeInOut(duration: 0.3)) { motion.selectedAccountID = account.id }
        let signpost = AppServices.signposter.beginInterval("DetailOpen")
        if reduceMotion {
            motion.progress = 1
            detailOpen = true
            AppServices.signposter.endInterval("DetailOpen", signpost)
            return
        }
        motion.isAnimating = true
        withAnimation(.linear(duration: DetailMotion.duration)) {
            motion.progress = 1
        } completion: {
            motion.isAnimating = false
            detailOpen = true
            AppServices.signposter.endInterval("DetailOpen", signpost)
        }
    }

    private func closeDetail() {
        guard selectedIndex != nil, !motion.isAnimating else { return }
        if let id = motion.selectedAccountID, let rect = geometry.cards[id] { source = rect }
        // 详情页滚动过时，从卡片当前的位置飞回
        destination.origin.y = AppLayout.detailTop - geometry.detailScrollOffset
        detailOpen = false
        let signpost = AppServices.signposter.beginInterval("DetailClose")
        let finish = {
            selectedIndex = nil
            withAnimation(.easeInOut(duration: 0.3)) { motion.selectedAccountID = nil }
            motion.isAnimating = false
            AppServices.signposter.endInterval("DetailClose", signpost)
        }
        if reduceMotion {
            motion.progress = 0
            finish()
            return
        }
        motion.isAnimating = true
        withAnimation(.linear(duration: DetailMotion.reverseDuration)) {
            motion.progress = 0
        } completion: {
            finish()
        }
    }
}

// MARK: - 转场修饰器（Animatable：每帧只改变换，不触发重新布局）

/// 选中卡之上的卡片收拢到选中卡的飞行位置后面；之下的卡片向下离场。
private struct StackCardMotion: ViewModifier, Animatable {
    var progress: Double
    let index: Int
    let selected: Int?
    let peek: CGFloat
    let travelOffset: CGFloat
    let exitDistance: CGFloat

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        var offset: CGFloat = 0
        if let selected, index != selected {
            if index < selected {
                let gap = CGFloat(selected - index) * peek
                offset = (travelOffset + gap) * DetailMotion.cardTravel(progress)
            } else {
                offset = DetailMotion.stackExit(progress) * exitDistance
            }
        }
        return content.offset(y: offset)
    }
}

/// 进度过了第二阶段后整个卡包隐藏（原型 Offstage），返回时再显示。
private struct StackVisibility: ViewModifier, Animatable {
    var progress: Double
    let active: Bool

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content.opacity(active && progress >= DetailMotion.secondStageEnd ? 0 : 1)
    }
}

/// 总览卡片随选中卡片的移动向上离场。
private struct OverviewExit: ViewModifier, Animatable {
    var progress: Double
    let distance: CGFloat
    let active: Bool

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content.offset(y: active ? -DetailMotion.cardTravel(progress) * distance : 0)
    }
}

/// 飞行中的选中卡片：在原位置与详情位置之间插值；被下一张卡遮住的部分用圆角遮罩裁掉。
private struct FlightCard<Card: View>: View, Animatable {
    var progress: Double
    let source: CGRect
    let destination: CGRect
    let nextCard: CGRect?
    let exitDistance: CGFloat
    let maskEnabled: Bool
    let card: (CGFloat, CGFloat) -> Card

    init(progress: Double, source: CGRect, destination: CGRect, nextCard: CGRect?, exitDistance: CGFloat, maskEnabled: Bool, @ViewBuilder card: @escaping (CGFloat, CGFloat) -> Card) {
        self.progress = progress
        self.source = source
        self.destination = destination
        self.nextCard = nextCard
        self.exitDistance = exitDistance
        self.maskEnabled = maskEnabled
        self.card = card
    }

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        let travel = DetailMotion.cardTravel(progress)
        let rect = CGRect(
            x: source.minX + (destination.minX - source.minX) * travel,
            y: source.minY + (destination.minY - source.minY) * travel,
            width: source.width + (destination.width - source.width) * travel,
            height: source.height + (destination.height - source.height) * travel
        )
        var occluder: CGRect?
        if maskEnabled, let nextCard {
            let lowerOffset = DetailMotion.stackExit(progress) * exitDistance
            occluder = nextCard.offsetBy(dx: -rect.minX, dy: lowerOffset - rect.minY)
        }
        return card(rect.height, travel)
            .frame(width: rect.width, height: rect.height)
            .mask {
                if let occluder {
                    Path { path in
                        path.addRect(CGRect(x: -24, y: -24, width: rect.width + 48, height: rect.height + 52))
                        path.addRoundedRect(in: occluder, cornerSize: CGSize(width: 20, height: 20), style: .continuous)
                    }
                    .fill(style: FillStyle(eoFill: true))
                } else {
                    Rectangle().padding(-24)
                }
            }
            .offset(x: rect.minX, y: rect.minY)
    }
}

// MARK: - 总览与空状态

/// 净资产卡：只显示净资产、总资产、总负债，右上角是隐藏金额按钮。
/// 每张卡取推算余额（银行通知余额或初始余额起算）；正数计入总资产，负数（欠款）计入总负债。
/// 信用卡通知里的「余额」含义因银行而异，只有填了初始余额的信用卡才计入。多币种时显示卡最多的币种。
private struct OverviewCard: View {
    @Binding var hideBalance: Bool
    @Environment(LedgerStore.self) private var store

    var body: some View {
        let totals = Self.totals(store.accounts, store.balances)
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
            Text(amount(totals?.net, totals?.currency))
                .font(.system(.largeTitle, design: .rounded).weight(.bold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.top, 2)
            HStack(spacing: 0) {
                figure("总资产", amount(totals?.assets, totals?.currency))
                figure("总负债", amount(totals?.liabilities, totals?.currency))
            }
            .padding(.top, 14)
        }
        .padding(18)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private func amount(_ minor: Int64?, _ currency: CurrencyCode?) -> String {
        if hideBalance { return "••••" }
        guard let minor, let currency else { return "—" }
        return Fmt.money(minor, currency)
    }

    private func figure(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.footnote).foregroundStyle(.secondary)
            Text(value).font(.headline).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    struct Totals {
        var currency: CurrencyCode
        var assets: Int64
        var liabilities: Int64
        var net: Int64 { assets - liabilities }
    }

    static func totals(_ accounts: [Account], _ balances: [String: AccountBalanceSummary]) -> Totals? {
        var byCurrency: [CurrencyCode: (assets: Int64, liabilities: Int64, cards: Int)] = [:]
        for account in accounts {
            guard let summary = balances[account.id] else { continue }
            if account.cardType == .credit, summary.base != .opening { continue }
            guard let amount = summary.ledgerDerivedMinor, let currency = summary.ledgerDerivedCurrency else { continue }
            var entry = byCurrency[currency] ?? (assets: 0, liabilities: 0, cards: 0)
            if amount >= 0 { entry.assets += amount } else { entry.liabilities += -amount }
            entry.cards += 1
            byCurrency[currency] = entry
        }
        guard let main = byCurrency.max(by: { $0.value.cards == $1.value.cards ? $0.key > $1.key : $0.value.cards < $1.value.cards }) else { return nil }
        return Totals(currency: main.key, assets: main.value.assets, liabilities: main.value.liabilities)
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
