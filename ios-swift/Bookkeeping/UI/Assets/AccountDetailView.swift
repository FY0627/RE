import SwiftUI
import BKModel

/// 账户详情（原型 `_buildAccountDetailView`）：顶部玻璃按钮、详情卡片、自动记账状态、余额、流水。
/// 按钮用系统液态玻璃样式和标准尺寸，文字用系统文字样式。
struct AccountDetailView: View {
    let account: Account
    let progress: Double
    let isOpen: Bool
    let viewport: CGSize
    let hideBalance: Bool
    let geometry: AssetsGeometryBox
    let openPending: () -> Void
    let close: () -> Void

    @Environment(LedgerStore.self) private var store
    @State private var rows: [RecordRow] = []
    @State private var hasMore = true
    @State private var total = 0
    @State private var loading = false
    @State private var showGuide = false
    @State private var showAppearance = false
    @State private var showOpeningBalance = false
    @State private var confirmHide = false
    @State private var selectedRecord: RecordRow?

    var body: some View {
        ZStack(alignment: .top) {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    WalletCardView(
                        account: account,
                        balanceText: store.balances[account.id]?.cardText ?? "余额未知",
                        hideBalance: hideBalance,
                        height: AppLayout.detailHeight(viewport.width),
                        elevation: 1
                    )
                    .opacity(isOpen ? 1 : 0)

                    content
                        .modifier(ContentEntrance(progress: progress, height: viewport.height))
                }
                .padding(.horizontal, AppLayout.cardInset)
                .padding(.top, AppLayout.detailTop)
                .padding(.bottom, 48)
            }
            .scrollIndicators(.hidden)
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y + $0.contentInsets.top } action: { _, offset in
                geometry.detailScrollOffset = offset
            }

            topBar
                .padding(.horizontal, AppLayout.cardInset)
                .padding(.top, 2)
        }
        .allowsHitTesting(isOpen)
        .simultaneousGesture(
            // 右滑返回卡包（左滑不响应，避免误触）
            DragGesture(minimumDistance: 24).onEnded { value in
                if value.translation.width > 70, abs(value.translation.height) < 60, value.predictedEndTranslation.width > 140 { close() }
            }
        )
        .task(id: TaskKey(account: account.id, revision: store.revision)) { await reload() }
        .sheet(isPresented: $showGuide) {
            NavigationStack { AutoSetupGuideView(account: account, onDone: { showGuide = false }) }
        }
        .sheet(isPresented: $showAppearance) { AppearancePicker(account: account) }
        .sheet(isPresented: $showOpeningBalance) { OpeningBalanceEditor(account: account) }
        .sheet(item: $selectedRecord) { row in RecordDetailSheet(recordID: row.id) }
        .confirmationDialog("隐藏这张卡？", isPresented: $confirmHide, titleVisibility: .visible) {
            Button("隐藏", role: .destructive) {
                close()
                Task { await store.setArchived(accountID: account.id, archived: true) }
            }
        } message: {
            Text("已有流水会保留。")
        }
    }

    private struct TaskKey: Hashable {
        let account: String
        let revision: Int
    }

    private func reload() async {
        let first = await store.records(accountID: account.id, after: nil)
        rows = first
        hasMore = first.count == 40
        total = await store.recordCount(accountID: account.id)
    }

    private func loadMore() async {
        guard hasMore, !loading else { return }
        loading = true
        let page = await store.records(accountID: account.id, after: rows.last)
        rows += page
        hasMore = page.count == 40
        loading = false
    }

    // MARK: 顶部按钮

    /// 与系统导航栏按钮同尺寸：44pt 圆形 / 胶囊，17pt 图标；右侧两个按钮共用一个玻璃胶囊（iOS 26 工具栏分组样式）。
    private var topBar: some View {
        HStack {
            Button(action: close) {
                toolbarIcon("chevron.left")
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: Circle())
            .accessibilityLabel("返回卡包")
            .modifier(CenteredControlScale(progress: progress, circular: true, stage: DetailMotion.topButtons))

            Spacer()

            HStack(spacing: 0) {
                Button { showGuide = true } label: {
                    toolbarIcon("bolt.badge.automatic")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("设置自动记账")
                Menu {
                    Button("初始余额", systemImage: "banknote") { showOpeningBalance = true }
                    Button("卡面外观", systemImage: "paintpalette") { showAppearance = true }
                    Button("隐藏这张卡", systemImage: "eye.slash", role: .destructive) { confirmHide = true }
                } label: {
                    toolbarIcon("ellipsis")
                }
                .accessibilityLabel("更多")
            }
            .glassEffect(.regular.interactive(), in: Capsule())
            .modifier(CenteredControlScale(progress: progress, circular: false, stage: DetailMotion.topButtons))
        }
    }

    private func toolbarIcon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(.primary)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }

    // MARK: 内容

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            automationStrip.padding(.top, 16)
            balanceCard.padding(.top, 16)
            quickActions.padding(.top, 16)
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
                        Button { selectedRecord = row } label: { RecordRowView(row: row, showAccount: false, boxed: true) }
                            .buttonStyle(.plain)
                            .onAppear { if row.id == rows.last?.id { Task { await loadMore() } } }
                    }
                }
            }
        }
    }

    private var automationStrip: some View {
        let status = store.automation[account.id]
        return Button { showGuide = true } label: {
            HStack(spacing: 12) {
                Image(systemName: status?.lastSuccessAt == nil ? "bolt.badge.clock" : "bolt.badge.checkmark")
                    .font(.title3)
                    .foregroundStyle(status?.lastSuccessAt == nil ? Color.orange : Color.green)
                    .frame(width: 44, height: 44)
                    .background(Color.primary.opacity(0.06), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text("自动记账").font(.headline).foregroundStyle(.primary)
                    if let last = status?.lastSuccessAt {
                        Text("已验证 · \(Fmt.dateTime(last))").font(.subheadline).foregroundStyle(.secondary)
                    } else {
                        Text("未验证").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var balanceCard: some View {
        let summary = store.balances[account.id]
        let derivedCurrency = summary?.ledgerDerivedCurrency ?? account.currency
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("余额").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Text(account.cardType.displayName)
                    .font(.footnote.weight(.medium))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Color.primary.opacity(0.06), in: Capsule())
            }
            if let derived = summary?.ledgerDerivedMinor {
                Text(hideBalance ? "••••••" : Fmt.money(derived, derivedCurrency))
                    .font(.system(.largeTitle, design: .rounded).weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(derived < 0 ? AppTheme.debt : Color.primary)
                    .lineLimit(1).minimumScaleFactor(0.6)
                    .padding(.top, 2)
            } else {
                Text("未知").font(.system(.largeTitle, design: .rounded).weight(.bold)).foregroundStyle(.secondary).padding(.top, 2)
            }

            Divider().padding(.vertical, 12)

            LabeledContent("银行通知余额") {
                if let reported = summary?.bankReported {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(hideBalance ? "••••" : Fmt.money(reported.amountMinor, reported.currency)).monospacedDigit().foregroundStyle(.primary)
                    }
                } else {
                    Text("未收到")
                }
            }
            .padding(.vertical, 4)

            Button { showOpeningBalance = true } label: {
                LabeledContent("初始余额") {
                    HStack(spacing: 6) {
                        if let opening = account.openingBalanceMinor {
                            Text(hideBalance ? "••••" : Fmt.money(opening, account.currency)).monospacedDigit()
                        } else {
                            Text("未填写")
                        }
                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("填写或修改这张卡的初始余额")
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }


    private var quickActions: some View {
        HStack(spacing: 8) {
            quickAction("自动记账", "bolt.badge.automatic") { showGuide = true }
            quickAction(store.pendingCount > 0 ? "待处理 \(store.pendingCount)" : "待处理", "tray", action: openPending)
            quickAction("卡面", "paintpalette") { showAppearance = true }
            quickAction("隐藏", "eye.slash") { confirmHide = true }
        }
    }

    private func quickAction(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.title3).frame(width: 52, height: 52)
                    .background(Color(.secondarySystemGroupedBackground), in: Circle())
                Text(title).font(.footnote.weight(.medium)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 详情内容在卡片落位后从下方进入（0.70 – 1）。
private struct ContentEntrance: ViewModifier, Animatable {
    var progress: Double
    let height: CGFloat

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let entrance = DetailMotion.contentEntrance(progress)
        content.opacity(entrance).offset(y: (1 - entrance) * height * 0.66)
    }
}

/// 填写或修改初始余额：记为「现在」的余额，之后到达的流水在它的基础上推算。
struct OpeningBalanceEditor: View {
    let account: Account
    @Environment(LedgerStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var isDebt = false
    @State private var saving = false
    @State private var errorText: String?

    private var value: MoneyInput.Value { MoneyInput.parse(text, negative: isDebt, currency: account.currency) }

    private var canSave: Bool {
        guard !saving, case .valid = value else { return false }
        return true
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    OpeningBalanceFields(text: $text, isDebt: $isDebt, currency: account.currency)
                } header: {
                    Text("\(account.bankName) ·\(account.last4) · \(account.currency.chineseName)")
                }
                if account.openingBalanceMinor != nil {
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
                if let opening = account.openingBalanceMinor {
                    isDebt = opening < 0
                    text = MoneyInput.editingText(opening, currency: account.currency)
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
            try await store.setOpeningBalance(accountID: account.id, amountMinor: minor)
            dismiss()
        } catch {
            errorText = "保存失败：\(error)"
        }
    }
}

/// 卡面外观：只改配色，不影响账户匹配。
struct AppearancePicker: View {
    let account: Account
    @Environment(LedgerStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var selection: String = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                PaletteGrid(selection: $selection).padding(16)
            }
            .navigationTitle("卡面外观")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消", systemImage: "xmark") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", systemImage: "checkmark") {
                        Task {
                            await store.updateAppearance(accountID: account.id, paletteID: selection)
                            dismiss()
                        }
                    }
                }
            }
            .onAppear { selection = account.paletteID }
        }
        .presentationDetents([.medium, .large])
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
