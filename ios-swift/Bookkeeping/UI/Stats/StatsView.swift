import SwiftUI
import BKModel

/// 统计：按月、按币种的真实收支（不做分类统计和复杂报表）。
struct StatsView: View {
    @Environment(LedgerStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    @State private var year = Calendar.current.component(.year, from: Date())
    @State private var month = Calendar.current.component(.month, from: Date())
    @State private var stats: MonthStats?

    var body: some View {
        let palette = Theme(scheme: scheme)
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("统计").font(.system(size: 24, weight: .bold)).foregroundStyle(palette.ink)
                        Text("\(Fmt.monthTitle(year: year, month: month)) · 按币种分别汇总").font(.system(size: 11)).foregroundStyle(palette.muted)
                    }
                    Spacer()
                    HStack(spacing: 4) {
                        monthButton("chevron.left", palette) { shift(-1) }
                        monthButton("chevron.right", palette) { shift(1) }
                    }
                }
                .padding(.top, 12)

                if let stats, !stats.currencies.isEmpty {
                    ForEach(stats.currencies, id: \.currency) { totals in
                        currencyCard(totals, palette).padding(.top, 18)
                    }
                    if !stats.accounts.isEmpty {
                        Text("按账户").font(.system(size: 15, weight: .semibold)).foregroundStyle(palette.ink).padding(.top, 22)
                        ForEach(stats.accounts, id: \.accountID) { total in
                            accountRow(total, palette)
                        }
                    }
                    if stats.holdCount + stats.failedCount > 0 {
                        Text("另有冻结/预授权 \(stats.holdCount) 笔、失败 \(stats.failedCount) 笔，不计入收支。")
                            .font(.system(size: 11)).foregroundStyle(palette.muted).padding(.top, 12)
                    }
                } else {
                    Text("这个月还没有已入账的流水。")
                        .font(.system(size: 13)).foregroundStyle(palette.muted)
                        .frame(maxWidth: .infinity).padding(.vertical, 60)
                }
                footnote(palette).padding(.top, 20)
                Color.clear.frame(height: 110)
            }
            .padding(.horizontal, 16)
        }
        .scrollIndicators(.hidden)
        .task(id: "\(year)-\(month)-\(store.revision)") { stats = await store.stats(year: year, month: month) }
    }

    private func shift(_ delta: Int) {
        var m = month + delta
        var y = year
        if m < 1 { m = 12; y -= 1 }
        if m > 12 { m = 1; y += 1 }
        month = m
        year = y
    }

    private func monthButton(_ symbol: String, _ palette: Theme, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(palette.ink)
                .frame(width: 34, height: 34).background(palette.surface, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(symbol == "chevron.left" ? "上个月" : "下个月")
    }

    private func currencyCard(_ t: MonthStats.CurrencyTotals, _ palette: Theme) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(t.currency.chineseName) · 支出").font(.system(size: 12)).foregroundStyle(palette.muted)
            Text(Fmt.money(t.expenseMinor, t.currency)).font(.system(size: 34, weight: .bold)).foregroundStyle(palette.ink)
                .lineLimit(1).minimumScaleFactor(0.6)
            HStack(spacing: 20) {
                metric("收入", Fmt.money(t.incomeMinor, t.currency), palette)
                metric("退款/冲正", Fmt.money(t.refundMinor, t.currency), palette)
                metric("净支出", Fmt.money(t.netExpenseMinor, t.currency), palette)
            }
            .padding(.top, 12)
            HStack(spacing: 20) {
                metric("内部转账（不计）", Fmt.money(t.internalTransferMinor, t.currency), palette)
                metric("还款（不计）", Fmt.money(t.repaymentMinor, t.currency), palette)
            }
            .padding(.top, 10)
            if !t.byKind.isEmpty {
                Divider().overlay(palette.line).padding(.vertical, 14)
                Text("按交易性质").font(.system(size: 12, weight: .medium)).foregroundStyle(palette.muted)
                let maxAmount = max(1, t.byKind.map(\.amountMinor).max() ?? 1)
                ForEach(t.byKind, id: \.self) { k in
                    HStack(spacing: 10) {
                        Image(systemName: k.kind.symbolName).font(.system(size: 13)).frame(width: 20).foregroundStyle(palette.ink)
                        Text("\(k.kind.displayName)\(k.direction == .inflow ? "（流入）" : "")").font(.system(size: 13)).foregroundStyle(palette.ink)
                            .frame(width: 96, alignment: .leading)
                        GeometryReader { proxy in
                            Capsule().fill(palette.ink.opacity(0.12))
                                .frame(width: max(4, proxy.size.width * CGFloat(Double(k.amountMinor) / Double(maxAmount))), height: 6)
                                .frame(maxHeight: .infinity)
                        }
                        .frame(height: 16)
                        Text(Fmt.money(k.amountMinor, t.currency)).font(.system(size: 12, weight: .semibold)).foregroundStyle(palette.ink)
                    }
                    .padding(.top, 8)
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .padding(18)
        .background(palette.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func metric(_ title: String, _ value: String, _ palette: Theme) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 10)).foregroundStyle(palette.muted)
            Text(value).font(.system(size: 13, weight: .semibold)).foregroundStyle(palette.ink).lineLimit(1).minimumScaleFactor(0.7)
        }
    }

    private func accountRow(_ total: MonthStats.AccountTotal, _ palette: Theme) -> some View {
        let account = store.account(id: total.accountID)
        return HStack {
            Text(account.map { "\($0.bankName) ·\($0.last4)" } ?? "已隐藏的账户").font(.system(size: 14, weight: .medium)).foregroundStyle(palette.ink)
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text("+" + Fmt.money(total.inflowMinor, total.currency)).font(.system(size: 12, weight: .semibold)).foregroundStyle(AppTheme.income)
                Text("-" + Fmt.money(total.outflowMinor, total.currency)).font(.system(size: 12, weight: .semibold)).foregroundStyle(palette.ink)
            }
        }
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) { Rectangle().fill(palette.line).frame(height: 0.5) }
    }

    private func footnote(_ palette: Theme) -> some View {
        Text("""
        口径：支出 = 已入账的流出（不含内部转账、还款）；收入 = 已入账的流入（不含内部转账、还款、退款、冲正）；\
        净支出 = 支出 − 退款/冲正。冻结、预授权和失败交易单独显示，不计入。不同币种分别汇总，不做汇率换算。
        """)
        .font(.system(size: 10))
        .foregroundStyle(palette.muted)
    }
}
