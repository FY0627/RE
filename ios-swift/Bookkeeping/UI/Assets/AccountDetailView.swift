import SwiftUI
import BKModel

/// 账户详情的内容区：待处理提示、余额、交易记录。显示在选中卡片的下方，卡片本身和顶部按钮由资产页负责。
/// 右上角菜单（卡片信息、编辑卡面、待处理账单）在资产页的顶部按钮里；自动记账的设置在「我的」里。
struct AccountDetailView: View {
    let account: Account
    let hideBalance: Bool
    let pendingCount: Int
    let openPending: () -> Void
    let close: () -> Void

    @Environment(LedgerStore.self) private var store
    @State private var rows: [RecordRow] = []
    @State private var hasMore = true
    @State private var total = 0
    @State private var loading = false
    @State private var showOpeningBalance = false
    @State private var selectedRecord: RecordRow?

    var body: some View {
        ScrollView(.vertical) {
            content
                .padding(.horizontal, AppLayout.cardInset)
                .padding(.top, 8)
                .padding(.bottom, 48)
        }
        .scrollIndicators(.hidden)
        .simultaneousGesture(
            // 右滑返回卡包（左滑不响应，避免误触）
            DragGesture(minimumDistance: 24).onEnded { value in
                if value.translation.width > 70, abs(value.translation.height) < 60, value.predictedEndTranslation.width > 140 { close() }
            }
        )
        .task(id: TaskKey(account: account.id, revision: store.revision)) { await reload() }
        .sheet(isPresented: $showOpeningBalance) { OpeningBalanceEditor(account: account) }
        .sheet(item: $selectedRecord) { row in RecordDetailSheet(recordID: row.id) }
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
                        Button { selectedRecord = row } label: { RecordRowView(row: row, showAccount: false, boxed: true) }
                            .buttonStyle(.plain)
                            .onAppear { if row.id == rows.last?.id { Task { await loadMore() } } }
                    }
                }
            }
        }
    }

    /// 只有这张卡有待处理的账单时出现。
    private var pendingStrip: some View {
        Button(action: openPending) {
            HStack(spacing: 12) {
                Image(systemName: "tray.full").font(.title3).foregroundStyle(AppTheme.debt)
                Text("\(pendingCount) 条账单待处理").font(.headline).foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
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
