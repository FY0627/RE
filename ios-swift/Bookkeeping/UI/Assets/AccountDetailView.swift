import SwiftUI
import BKModel

/// 账户详情的内容区：待处理提示、余额、交易记录。显示在选中卡片的下方，卡片本身和顶部按钮由资产页负责。
/// 右上角菜单（卡片信息、编辑卡面、待处理账单）在资产页的顶部按钮里；自动记账的设置在「我的」里。
///
/// 滚动区从页面顶端开始，最上面是卡片，和下面的内容在同一个滚动区里，一起由系统滚动。
/// 打开时选中的卡画在这里（卡包里那张隐藏），转场中也能顺畅滚动，卡片和内容始终一起动：
/// 打开 / 关闭时只有区内的卡片（`cardLift`）和内容（`contentShown`）做位移动画，滚动区本身不动。
/// 卡包里在它下面的卡（`belowCards`）也画在这里、叠在它上层，和卡包一样压住它的下半部分，也压在内容上面；
/// 它们不随详情滚动，落出屏幕后就看不见了。返回时卡片交回卡包（`showsCards` 为 false），这里只剩内容淡出。
/// 和钱包一样，在顶部往下拉时卡片不动，只有下面的内容被拉开。点按卡片返回卡包。
struct AccountDetailView: View {
    /// 卡包里在选中卡下面的一张卡
    struct BelowCard: Identifiable {
        let account: Account
        /// 相对选中卡片顶部位置的位移（不算详情的滚动）
        let lift: CGFloat
        var id: String { account.id }
    }

    let account: Account
    let pendingCount: Int
    /// 滚动区顶端到卡片上边缘的距离
    let cardTop: CGFloat
    let cardHeight: CGFloat
    /// 卡片相对顶部位置的位移：打开后为 0，打开前 / 关闭后是它在卡包里的位置
    let cardLift: CGFloat
    let belowCards: [BelowCard]
    /// 卡片是否画在这里；返回途中由卡包里的卡接着动
    let showsCards: Bool
    let contentShown: Bool
    let scrollLocked: Bool
    /// 记录滚动距离，关闭时资产页据此算出卡片当前的位置
    let box: AssetsScrollBox
    let openPending: () -> Void
    let close: () -> Void

    @Environment(LedgerStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 第一页流水和笔数是否已读到。读到之前内容不升起：否则内容先升完，流水才突然出现在原位
    @State private var loaded = false
    @State private var rows: [RecordRow] = []
    @State private var hasMore = true
    @State private var total = 0
    @State private var loading = false
    @State private var openingTarget: OpeningTarget?
    @State private var selectedRecord: RecordRow?
    /// 滚动区顶部的内容边距（状态栏）；第一次滚动时得到，之前没有滚动，不需要修正
    @State private var insetTop: CGFloat?

    var body: some View {
        ScrollView(.vertical) {
            VStack(spacing: 0) {
                // 和卡包里的卡同样的画法、同样的位置，交接时看不出变化
                ZStack(alignment: .top) {
                    WalletCardView(account: account, balanceText: store.balances[account.id]?.cardText ?? "余额未知")
                        .grayscale(account.archived ? 1 : 0)
                        .frame(height: cardHeight)
                        // 点按区域放在位移之前，跟着卡片移动
                        .contentShape(Rectangle())
                        .onTapGesture(perform: close)
                        .offset(y: cardLift)
                        // 往下拉时抵消下移的距离，卡片停在原处；放在转场位移之后，量到的只是滚动造成的移动
                        .visualEffect { [restY = restY] content, proxy in
                            content.offset(y: min(0, Self.scrolled(proxy, restY: restY)))
                        }
                        .accessibilityAddTraits(.isButton)
                        .accessibilityHint("返回卡包")
                    belowStack
                }
                .opacity(showsCards ? 1 : 0)
                .accessibilityHidden(!showsCards)
                .padding(.top, cardTop)
                // 下面的卡压在内容上面；往下拉时内容在卡片下面被拉开
                .zIndex(1)
                content
                    .padding(.top, 8)
                    .padding(.bottom, 48)
                    // 隐藏时移到屏幕下方：打开时整块从屏幕底下升上来，返回时退下去。
                    // 用只影响绘制的位移：offset 会让流水列表以为自己在屏幕外、不生成流水，
                    // 动画途中才临时生成的流水不跟着动，直接出现在终点
                    .visualEffect { [rise = contentShown && loaded ? 0 : box.pageSize.height] content, _ in
                        content.offset(y: rise)
                    }
                    .opacity(contentShown ? 1 : 0)
                    .accessibilityHidden(!contentShown)
            }
            .padding(.horizontal, AppLayout.cardInset)
        }
        .scrollIndicators(.hidden)
        .scrollDisabled(scrollLocked)
        .onScrollGeometryChange(for: ScrollState.self) {
            ScrollState(offset: $0.contentOffset.y + $0.contentInsets.top, insetTop: $0.contentInsets.top)
        } action: { _, state in
            box.detailOffset = state.offset
            if insetTop != state.insetTop { insetTop = state.insetTop }
        }
        .simultaneousGesture(
            // 右滑返回卡包（左滑不响应，避免误触）
            DragGesture(minimumDistance: 24).onEnded { value in
                if value.translation.width > 70, abs(value.translation.height) < 60, value.predictedEndTranslation.width > 140 { close() }
            }
        )
        .task(id: TaskKey(account: account.id, revision: store.revision)) { await reload() }
        .sheet(item: $openingTarget) { target in OpeningBalanceEditor(account: account, currency: target.currency) }
        .sheet(item: $selectedRecord) { row in RecordDetailSheet(recordID: row.id) }
    }

    private struct TaskKey: Hashable {
        let account: String
        let revision: Int
    }

    private struct ScrollState: Equatable {
        let offset: CGFloat
        let insetTop: CGFloat
    }

    /// 没滚动时卡片位置在滚动区坐标里的 y；还不知道内容边距时为 nil
    private var restY: CGFloat? { insetTop.map { $0 + cardTop } }

    /// 卡片位置因滚动向上移动的距离（往下拉时为负）；还不知道内容边距时按没滚动算
    private nonisolated static func scrolled(_ proxy: GeometryProxy, restY: CGFloat?) -> CGFloat {
        guard let restY else { return 0 }
        return restY - proxy.frame(in: .scrollView(axis: .vertical)).minY
    }

    /// 下面的卡，按卡包里的顺序叠在选中的卡上层。按滚动反向移动，始终和卡包里的位置对齐（卡包不随详情滚动）
    private var belowStack: some View {
        ZStack(alignment: .top) {
            ForEach(belowCards) { card in
                WalletCardView(account: card.account, balanceText: store.balances[card.account.id]?.cardText ?? "余额未知")
                    .grayscale(card.account.archived ? 1 : 0)
                    .frame(height: cardHeight)
                    .offset(y: card.lift)
            }
        }
        .visualEffect { [restY = restY] content, proxy in
            content.offset(y: Self.scrolled(proxy, restY: restY))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func reload() async {
        let first = await store.records(accountID: account.id, after: nil)
        let count = await store.recordCount(accountID: account.id)
        rows = first
        hasMore = first.count == 40
        total = count
        guard !loaded else { return }
        // 等流水先画出来一帧，再和其他内容一起从底下升上来（和资产页的入场动画相同）
        try? await Task.sleep(for: .milliseconds(10))
        guard !Task.isCancelled else { return }
        withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.5, dampingFraction: 1)) { loaded = true }
    }

    private func loadMore() async {
        guard hasMore, !loading else { return }
        loading = true
        let page = await store.records(accountID: account.id, after: rows.last)
        rows += page
        hasMore = page.count == 40
        loading = false
    }

    // MARK: 内容

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            if pendingCount > 0 {
                pendingStrip.padding(.bottom, 16)
            }
            balanceCard
            HStack(alignment: .firstTextBaseline) {
                Text("交易记录").font(.title3.weight(.semibold))
                Spacer()
                Text("共 \(total) 笔").font(.subheadline).foregroundStyle(.secondary)
            }
            .padding(.top, 24)
            .padding(.bottom, 10)
            if rows.isEmpty {
                Text("暂无流水")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 28)
                    .multilineTextAlignment(.center)
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(rows) { row in
                        RecordRowView(row: row, showAccount: false, boxed: true)
                            .tapAction { selectedRecord = row }
                            .onAppear { if row.id == rows.last?.id { Task { await loadMore() } } }
                    }
                }
            }
        }
    }

    /// 只有这张卡有待处理的账单时出现。
    private var pendingStrip: some View {
        HStack(spacing: 12) {
            Image(systemName: "tray.full").font(.title3).foregroundStyle(AppTheme.debt)
            Text("\(pendingCount) 条账单待处理").font(.headline).foregroundStyle(.primary)
            Spacer()
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .tapAction(openPending)
    }

    /// 单币种：大字余额 + 银行通知余额 + 初始余额。多币种：每个币种一组，各自的余额、银行通知余额和初始余额，不做换算。
    private var balanceCard: some View {
        let items = store.balances[account.id]?.items ?? []
        let currencies = items.isEmpty ? account.currencies : items.map(\.currency)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(account.isMultiCurrency ? "余额（多币种）" : "余额").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Text(account.cardType.displayName)
                    .font(.footnote.weight(.medium))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Color.primary.opacity(0.06), in: Capsule())
            }
            ForEach(Array(currencies.enumerated()), id: \.element) { index, currency in
                if index > 0 { Divider().padding(.vertical, 12) }
                currencyBalance(currency, summary: items.first { $0.currency == currency }, large: currencies.count == 1)
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    @ViewBuilder
    private func currencyBalance(_ currency: CurrencyCode, summary: AccountBalanceSummary?, large: Bool) -> some View {
        let amountFont: Font = large ? .system(.largeTitle, design: .rounded).weight(.bold) : .system(.title2, design: .rounded).weight(.bold)
        VStack(alignment: .leading, spacing: 0) {
            if !large {
                Text("\(currency.chineseName) \(currency.rawValue)").font(.subheadline.weight(.medium)).padding(.top, 2)
            }
            if let derived = summary?.ledgerDerivedMinor {
                Text(Fmt.money(derived, currency))
                    .font(amountFont)
                    .monospacedDigit()
                    .foregroundStyle(derived < 0 ? AppTheme.debt : Color.primary)
                    .lineLimit(1).minimumScaleFactor(0.6)
                    .padding(.top, 2)
            } else {
                Text("未知").font(amountFont).foregroundStyle(.secondary).padding(.top, 2)
            }

            if large { Divider().padding(.vertical, 12) }

            LabeledContent("初始余额") {
                HStack(spacing: 6) {
                    if let opening = account.openingBalance(currency) {
                        Text(Fmt.money(opening.amountMinor, currency)).monospacedDigit()
                    } else {
                        Text("未填写")
                    }
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 4)
            .tapAction { openingTarget = OpeningTarget(currency: currency) }
            .accessibilityHint("填写或修改这个币种的初始余额")
        }
    }
}

private extension View {
    /// 点按执行。不用 Button：按钮在手指横向划过后松手仍会触发，右滑返回时会同时点开流水；点按手势一移动就不算
    func tapAction(_ action: @escaping () -> Void) -> some View {
        contentShape(Rectangle())
            .onTapGesture(perform: action)
            .accessibilityAddTraits(.isButton)
    }
}

/// 要编辑初始余额的币种（用作 sheet 的标识）
struct OpeningTarget: Identifiable {
    let currency: CurrencyCode
    var id: String { currency.rawValue }
}

/// 填写或修改某个币种的初始余额：记为「现在」的余额，之后到达的同币种流水在它的基础上推算。
struct OpeningBalanceEditor: View {
    let account: Account
    let currency: CurrencyCode
    @Environment(LedgerStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var isDebt = false
    @State private var saving = false
    @State private var errorText: String?

    private var value: MoneyInput.Value { MoneyInput.parse(text, negative: isDebt, currency: currency) }

    private var canSave: Bool {
        guard !saving, case .valid = value else { return false }
        return true
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    OpeningBalanceFields(text: $text, isDebt: $isDebt, currency: currency)
                } header: {
                    Text("\(account.bankName) ·\(account.last4) · \(currency.chineseName)")
                }
                if account.openingBalance(currency) != nil {
                    Section {
                        Button("清除初始余额", role: .destructive) { Task { await save(nil) } }
                    }
                }
                if let errorText {
                    Section { Text(errorText).foregroundStyle(.red) }
                }
            }
            .navigationTitle("初始余额")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消", systemImage: "xmark") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", systemImage: "checkmark") {
                        if case .valid(let minor) = value { Task { await save(minor) } }
                    }
                    .disabled(!canSave)
                }
            }
            .onAppear {
                if let opening = account.openingBalance(currency) {
                    isDebt = opening.amountMinor < 0
                    text = MoneyInput.editingText(opening.amountMinor, currency: currency)
                } else {
                    isDebt = account.cardType == .credit
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func save(_ minor: Int64?) async {
        saving = true
        defer { saving = false }
        do {
            try await store.setOpeningBalance(accountID: account.id, currency: currency, amountMinor: minor)
            dismiss()
        } catch {
            errorText = "保存失败：\(error)"
        }
    }
}

struct PaletteGrid: View {
    @Binding var selection: String

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 12)], spacing: 12) {
            ForEach(CardPalette.all) { palette in
                Button { selection = palette.id } label: {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(palette.gradient)
                        .frame(height: 64)
                        .overlay(alignment: .bottomLeading) {
                            Text(palette.name).font(.footnote.weight(.semibold)).foregroundStyle(palette.textColor).padding(10)
                        }
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(Color.accentColor, lineWidth: selection == palette.id ? 3 : 0)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(palette.name)
                .accessibilityAddTraits(selection == palette.id ? [.isSelected] : [])
            }
        }
    }
}
