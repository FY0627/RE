import SwiftUI
import BKModel

/// 统计：按月、按币种的真实收支（不做分类统计和复杂报表）。系统导航栏 + 分组列表，切换月份在导航栏右侧。
struct StatsView: View {
    @Environment(LedgerStore.self) private var store
    @State private var year = Calendar.current.component(.year, from: Date())
    @State private var month = Calendar.current.component(.month, from: Date())
    @State private var stats: MonthStats?

    var body: some View {
        NavigationStack {
            List {
                if let stats, !stats.currencies.isEmpty {
                    ForEach(stats.currencies, id: \.currency) { totals in
                        currencySection(totals, isFirst: totals.currency == stats.currencies.first?.currency)
                    }
                    if !stats.accounts.isEmpty {
                        Section("按账户") {
                            ForEach(stats.accounts, id: \.accountID) { accountRow($0) }
                        }
                    }
                } else {
                    Section {
                        ContentUnavailableView("这个月还没有已入账的流水", systemImage: "chart.bar", description: Text(Fmt.monthTitle(year: year, month: month)))
                    } header: {
                        Text(Fmt.monthTitle(year: year, month: month))
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("统计")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("上个月", systemImage: "chevron.left") { shift(-1) }
                    Button("下个月", systemImage: "chevron.right") { shift(1) }
                }
            }
            .task(id: "\(year)-\(month)-\(store.revision)") { stats = await store.stats(year: year, month: month) }
        }
    }

    private func shift(_ delta: Int) {
        var m = month + delta
        var y = year
        if m < 1 { m = 12; y -= 1 }
        if m > 12 { m = 1; y += 1 }
        month = m
        year = y
    }

    private func currencySection(_ t: MonthStats.CurrencyTotals, isFirst: Bool) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 2) {
                Text("支出").font(.subheadline).foregroundStyle(.secondary)
                Text(Fmt.money(t.expenseMinor, t.currency))
                    .font(.system(.largeTitle, design: .rounded).weight(.bold))
                    .monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.6)
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
            LabeledContent("收入", value: Fmt.money(t.incomeMinor, t.currency))
            LabeledContent("退款/冲正", value: Fmt.money(t.refundMinor, t.currency))
            LabeledContent("净支出", value: Fmt.money(t.netExpenseMinor, t.currency))
            LabeledContent("内部转账（不计入）", value: Fmt.money(t.internalTransferMinor, t.currency))
            LabeledContent("还款（不计入）", value: Fmt.money(t.repaymentMinor, t.currency))
            if !t.byKind.isEmpty {
                let maxAmount = max(1, t.byKind.map(\.amountMinor).max() ?? 1)
                ForEach(t.byKind, id: \.self) { k in
                    kindRow(k, currency: t.currency, maxAmount: maxAmount)
                }
            }
        } header: {
            Text(isFirst ? "\(Fmt.monthTitle(year: year, month: month)) · \(t.currency.chineseName)" : t.currency.chineseName)
        }
    }

    private func kindRow(_ k: MonthStats.KindTotal, currency: CurrencyCode, maxAmount: Int64) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("\(k.kind.displayName)\(k.direction == .inflow ? "（流入）" : "")", systemImage: k.kind.symbolName)
                Spacer()
                Text(Fmt.money(k.amountMinor, currency)).monospacedDigit().foregroundStyle(.secondary)
            }
            GeometryReader { proxy in
                Capsule().fill(Color.primary.opacity(0.12))
                    .frame(width: max(6, proxy.size.width * CGFloat(Double(k.amountMinor) / Double(maxAmount))), height: 6)
            }
            .frame(height: 6)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private func accountRow(_ total: MonthStats.AccountTotal) -> some View {
        let account = store.account(id: total.accountID)
        return HStack {
            Text(account.map { "\($0.bankName) ·\($0.last4)" } ?? "已删除的账户")
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("+" + Fmt.money(total.inflowMinor, total.currency)).foregroundStyle(AppTheme.income)
                Text("-" + Fmt.money(total.outflowMinor, total.currency))
            }
            .font(.subheadline.weight(.semibold))
            .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }

}
