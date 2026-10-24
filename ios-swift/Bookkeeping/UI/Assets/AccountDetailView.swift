import SwiftUI
import BKModel

/// 账户详情（原型 `_buildAccountDetailView`）：顶部玻璃按钮、详情卡片、自动记账状态条、余额卡、流水。
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
    @Environment(\.colorScheme) private var scheme
    @State private var rows: [RecordRow] = []
    @State private var hasMore = true
    @State private var total = 0
    @State private var loading = false
    @State private var showGuide = false
    @State private var showAppearance = false
    @State private var confirmHide = false
    @State private var selectedRecord: RecordRow?

    var body: some View {
        let palette = Theme(scheme: scheme)
        ZStack(alignment: .top) {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    WalletCardView(
                        account: account,
                        balanceText: store.balances[account.id]?.cardText(currency: account.currency) ?? "余额未知",
                        hideBalance: hideBalance,
                        height: AppLayout.detailHeight(viewport.width),
                        elevation: 1
                    )
                    .opacity(isOpen ? 1 : 0)

                    content(palette)
                        .modifier(ContentEntrance(progress: progress, height: viewport.height))
                }
                .padding(.horizontal, AppLayout.cardInset)
                .padding(.top, AppLayout.detailTop)
                .padding(.bottom, 40)
            }
            .scrollIndicators(.hidden)
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y + $0.contentInsets.top } action: { _, offset in
                geometry.detailScrollOffset = offset
            }

            topBar(palette)
                .padding(.horizontal, AppLayout.cardInset)
                .padding(.top, 8)
        }
        .allowsHitTesting(isOpen)
        .simultaneousGesture(
            // 右滑返回卡包（左滑不响应，避免误触）
            DragGesture(minimumDistance: 24).onEnded { value in
                if value.translation.width > 70, abs(value.translation.height) < 60, value.predictedEndTranslation.width > 140 { close() }
            }
        )
        .task(id: TaskKey(account: account.id, revision: store.revision)) { await reload() }
        .sheet(isPresented: $showGuide) { NavigationStack { AutoSetupGuideView(account: account) } }
        .sheet(isPresented: $showAppearance) { AppearancePicker(account: account) }
        .sheet(item: $selectedRecord) { row in RecordDetailView(recordID: row.id) }
        .confirmationDialog("隐藏这张卡？", isPresented: $confirmHide, titleVisibility: .visible) {
            Button("隐藏", role: .destructive) {
                close()
                Task { await store.setArchived(accountID: account.id, archived: true) }
            }
        } message: {
            Text("隐藏后不再参与匹配新通知，已有流水保留在首页。")
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

    private func topBar(_ palette: Theme) -> some View {
        HStack {
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 16, weight: .semibold)).foregroundStyle(palette.ink)
                    .frame(width: 38, height: 38)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .chromeBackground(Circle())
            .accessibilityLabel("返回卡包")
            .modifier(CenteredControlScale(progress: progress, circular: true, stage: DetailMotion.topButtons))

            Spacer()

            HStack(spacing: 0) {
                Button { showGuide = true } label: {
                    Image(systemName: "bolt.badge.automatic").font(.system(size: 15)).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .accessibilityLabel("设置自动记账")
                Rectangle().fill(palette.ink.opacity(palette.isDark ? 0.22 : 0.18)).frame(width: 0.75, height: 16)
                Menu {
                    Button("卡面外观", systemImage: "paintpalette") { showAppearance = true }
                    Button("隐藏这张卡", systemImage: "eye.slash", role: .destructive) { confirmHide = true }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 16)).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .accessibilityLabel("更多")
            }
            .buttonStyle(.plain)
            .foregroundStyle(palette.ink)
            .frame(width: 84, height: 38)
            .chromeBackground(Capsule())
            .modifier(CenteredControlScale(progress: progress, circular: false, stage: DetailMotion.topButtons))
        }
    }

    // MARK: 内容

    private func content(_ palette: Theme) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            automationStrip(palette).padding(.top, 16)
            balanceCard(palette).padding(.top, 16)
            HStack {
                Text("近期交易记录").font(.system(size: 15, weight: .semibold)).foregroundStyle(palette.ink)
                Spacer()
                Text("共 \(total) 笔").font(.system(size: 11)).foregroundStyle(palette.muted)
            }
            .padding(.top, 20)
            .padding(.bottom, 10)
            if rows.isEmpty {
                Text("这张卡还没有流水。设置自动记账后，收到的银行通知会出现在这里。")
                    .font(.system(size: 12)).foregroundStyle(palette.muted)
                    .frame(maxWidth: .infinity).padding(.vertical, 28)
                    .multilineTextAlignment(.center)
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(rows) { row in
                        Button { selectedRecord = row } label: { RecordRowView(row: row, showAccount: false) }
                            .buttonStyle(.plain)
                            .onAppear { if row.id == rows.last?.id { Task { await loadMore() } } }
                    }
                }
            }
        }
    }

    private func automationStrip(_ palette: Theme) -> some View {
        let status = store.automation[account.id]
        let card = CardPalette.named(account.paletteID)
        return Button { showGuide = true } label: {
            HStack(spacing: 12) {
                Circle().fill(card.textColor == Color(hex: 0xFFFFFF) ? Color(hex: card.colors[0]).opacity(0.18) : card.textColor.opacity(0.12))
                    .frame(width: 36, height: 36)
                    .overlay(Image(systemName: "bolt.badge.automatic").font(.system(size: 16)).foregroundStyle(palette.ink))
                VStack(alignment: .leading, spacing: 2) {
                    Text("来自：\(account.bankName) · 自动记账").font(.system(size: 13, weight: .semibold)).foregroundStyle(palette.ink)
                    if let last = status?.lastSuccessAt {
                        Text("已验证 · 最近一次接收 \(Fmt.dateTime(last))（\(status?.lastSuccessSource?.displayName ?? "")）")
                            .font(.system(size: 11)).foregroundStyle(palette.muted)
                    } else {
                        Text("待验证 · 还没有收到这张卡的自动记账输入")
                            .font(.system(size: 11)).foregroundStyle(palette.muted)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(palette.muted)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(palette.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func balanceCard(_ palette: Theme) -> some View {
        let summary = store.balances[account.id]
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("银行通知余额").font(.system(size: 12)).foregroundStyle(palette.muted)
                Spacer()
                Text(account.cardType.displayName)
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(palette.ink)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(palette.ink.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            }
            if let reported = summary?.bankReported {
                Text(hideBalance ? "••••••••" : Fmt.money(reported.amountMinor, reported.currency))
                    .font(.system(size: 32, weight: .bold)).tracking(-0.8)
                    .foregroundStyle(reported.amountMinor < 0 ? AppTheme.debt : palette.ink)
                    .padding(.top, 6)
                Text("截至 \(reported.transactionTime?.displayText ?? Fmt.dateTime(reported.observedAt))（\(reported.transactionTime == nil ? "接收/处理时间" : "通知内时间")）")
                    .font(.system(size: 11)).foregroundStyle(palette.muted)
            } else {
                Text("未知").font(.system(size: 32, weight: .bold)).foregroundStyle(palette.muted).padding(.top, 6)
                Text("还没有收到包含余额的通知；不会用部分流水推算真实余额。").font(.system(size: 11)).foregroundStyle(palette.muted)
            }
            Divider().overlay(palette.line).padding(.vertical, 12)
            HStack {
                Text("账本推算余额").font(.system(size: 12)).foregroundStyle(palette.muted)
                Spacer()
                if let derived = summary?.ledgerDerivedMinor, let reported = summary?.bankReported {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(hideBalance ? "••••" : Fmt.money(derived, reported.currency)).font(.system(size: 14, weight: .semibold)).foregroundStyle(palette.ink)
                        Text(summary?.recordsAfterBase == 0 ? "与通知余额一致" : "通知余额 + 之后 \(summary?.recordsAfterBase ?? 0) 笔流水")
                            .font(.system(size: 10)).foregroundStyle(palette.muted)
                    }
                } else {
                    Text("未知").font(.system(size: 14, weight: .semibold)).foregroundStyle(palette.muted)
                }
            }
            Divider().overlay(palette.line).padding(.vertical, 12)
            HStack {
                quickAction("设置自动记账", "bolt.badge.automatic", palette) { showGuide = true }
                quickAction(store.pendingCount > 0 ? "待处理 \(store.pendingCount)" : "待处理", "tray", palette, action: openPending)
                quickAction("卡面外观", "paintpalette", palette) { showAppearance = true }
                quickAction("隐藏卡片", "eye.slash", palette) { confirmHide = true }
            }
        }
        .padding(16)
        .background(palette.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func quickAction(_ title: String, _ symbol: String, _ palette: Theme, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 18)).foregroundStyle(palette.ink)
                    .frame(width: 42, height: 42).background(palette.ink.opacity(0.05), in: Circle())
                Text(title).font(.system(size: 10, weight: .medium)).foregroundStyle(palette.ink).lineLimit(1)
            }
            .frame(maxWidth: .infinity)
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
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        Task {
                            await store.updateAppearance(accountID: account.id, paletteID: selection)
                            dismiss()
                        }
                    }
                }
            }
            .onAppear { selection = account.paletteID }
        }
        .presentationDetents([.medium])
    }
}

struct PaletteGrid: View {
    @Binding var selection: String

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 10)], spacing: 10) {
            ForEach(CardPalette.all) { palette in
                Button { selection = palette.id } label: {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(palette.gradient)
                        .frame(height: 56)
                        .overlay(alignment: .bottomLeading) {
                            Text(palette.name).font(.system(size: 11, weight: .semibold)).foregroundStyle(palette.textColor).padding(8)
                        }
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
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
