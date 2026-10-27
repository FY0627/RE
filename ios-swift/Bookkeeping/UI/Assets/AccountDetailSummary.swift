import SwiftUI
import BKModel

/// 卡片详情里卡片下面、流水之前的部分：待处理提示、余额、「交易记录」标题（没有流水时还有「暂无流水」）。
/// 放在详情列表（`WalletDetailList`）里；卡片本身、流水和顶部按钮在别处。
/// 右上角菜单（卡片信息、编辑卡面、待处理账单）在资产页的顶部按钮里；自动记账的设置在「我的」里。
struct AccountDetailSummary: View {
    let accountID: String
    let model: WalletDetailModel
    let openPending: () -> Void
    let editOpeningBalance: (CurrencyCode) -> Void

    @Environment(LedgerStore.self) private var store

    var body: some View {
        if let account = store.account(id: accountID) {
            VStack(alignment: .leading, spacing: 0) {
                if model.pendingCount > 0 {
                    pendingStrip.padding(.bottom, 16)
                }
                balanceCard(account)
                HStack(alignment: .firstTextBaseline) {
                    Text("交易记录").font(.title3.weight(.semibold))
                    Spacer()
                    Text("共 \(model.recordTotal) 笔").font(.subheadline).foregroundStyle(.secondary)
                }
                .padding(.top, 24)
                .padding(.bottom, 10)
                if !model.hasRecords {
                    Text("暂无流水")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).padding(.vertical, 28)
                        .multilineTextAlignment(.center)
                }
            }
        }
    }

    /// 只有这张卡有待处理的账单时出现。
    private var pendingStrip: some View {
        HStack(spacing: 12) {
            Image(systemName: "tray.full").font(.title3).foregroundStyle(AppTheme.debt)
            Text("\(model.pendingCount) 条账单待处理").font(.headline).foregroundStyle(.primary)
            Spacer()
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .tapAction(openPending)
    }

    /// 单币种：大字余额 + 初始余额。多币种：每个币种一组，各自的余额和初始余额，不做换算。
    private func balanceCard(_ account: Account) -> some View {
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
                currencyBalance(account, currency, summary: items.first { $0.currency == currency }, large: currencies.count == 1)
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    @ViewBuilder
    private func currencyBalance(_ account: Account, _ currency: CurrencyCode, summary: AccountBalanceSummary?, large: Bool) -> some View {
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
            .tapAction { editOpeningBalance(currency) }
            .accessibilityHint("填写或修改这个币种的初始余额")
        }
    }
}

private extension View {
    /// 点按执行。不用 Button：按钮在手指横向划过后松手仍会触发，右滑返回时会同时点开它；点按手势一移动就不算
    func tapAction(_ action: @escaping () -> Void) -> some View {
        contentShape(Rectangle())
            .onTapGesture(perform: action)
            .accessibilityAddTraits(.isButton)
    }
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
