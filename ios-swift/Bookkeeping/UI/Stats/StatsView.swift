import SwiftUI
import BKModel

/// 统计：按月看。先看支出、收入、结余，再按分类排（哪一类花得最多，点进去看小类和每一笔），最后按账户看。
/// 转帐（自己的账户之间、还信用卡、存取现金）不算在收支里；退款从它所在的分类里减掉。
/// 多个币种分开统计，不换算。系统导航栏 + 分组列表，切换月份在导航栏右侧。
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
                        currencySections(totals, isFirst: totals.currency == stats.currencies.first?.currency)
                    }
                    if !stats.accounts.isEmpty {
                        Section("按账户") {
                            ForEach(stats.accounts, id: \.self) { accountRow($0) }
                        }
                    }
                } else {
                    Section {
                        ContentUnavailableView("这个月还没有记录", systemImage: "chart.bar", description: Text(Fmt.monthTitle(year: year, month: month)))
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

    /// 这个月的时间范围（按收到通知的时间）
    private var range: (from: Date?, to: Date?) {
        let calendar = Calendar.current
        guard let start = calendar.date(from: DateComponents(year: year, month: month, day: 1)) else { return (nil, nil) }
        return (start, calendar.date(byAdding: .month, value: 1, to: start))
    }

    @ViewBuilder
    private func currencySections(_ t: MonthStats.CurrencyTotals, isFirst: Bool) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 2) {
                Text("支出").font(.subheadline).foregroundStyle(.secondary)
                Text(Fmt.money(t.netExpenseMinor, t.currency))
                    .font(.system(.largeTitle, design: .rounded).weight(.bold))
                    .monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.6)
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
            LabeledContent("收入", value: Fmt.money(t.incomeMinor, t.currency))
            LabeledContent("结余", value: Fmt.money(t.balanceMinor, t.currency))
            if t.refundMinor > 0 {
                LabeledContent("其中退款", value: Fmt.money(t.refundMinor, t.currency))
            }
            if t.transferMinor > 0 {
                LabeledContent("转帐（不算收支）", value: Fmt.money(t.transferMinor, t.currency))
            }
        } header: {
            Text(isFirst ? "\(Fmt.monthTitle(year: year, month: month)) · \(t.currency.chineseName)" : t.currency.chineseName)
        }
        if !t.expenseCategories.isEmpty {
            Section("支出分类") {
                categoryRows(t.expenseCategories, type: .expense, currency: t.currency, total: t.netExpenseMinor)
            }
        }
        if !t.incomeCategories.isEmpty {
            Section("收入分类") {
                categoryRows(t.incomeCategories, type: .income, currency: t.currency, total: t.incomeMinor)
            }
        }
    }

    private func categoryRows(_ totals: [MonthStats.CategoryTotal], type: EntryType, currency: CurrencyCode, total: Int64) -> some View {
        let maxAmount = max(1, totals.map(\.amountMinor).max() ?? 1)
        return ForEach(totals) { item in
            NavigationLink {
                CategoryStatsView(item: item, type: type, currency: currency, from: range.from, to: range.to)
            } label: {
                CategoryTotalRow(item: item, currency: currency, maxAmount: maxAmount, total: total)
            }
        }
    }

    private func accountRow(_ total: MonthStats.AccountTotal) -> some View {
        let account = store.account(id: total.accountID)
        return HStack {
            Text(account?.displayTitle ?? "已删除的账户")
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

/// 一个分类的合计：图标、名称、占比、金额和一条比例条
private struct CategoryTotalRow: View {
    let item: MonthStats.CategoryTotal
    let currency: CurrencyCode
    let maxAmount: Int64
    let total: Int64

    var body: some View {
        HStack(spacing: 12) {
            CategoryIcon(symbol: item.symbol)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(item.name).lineLimit(1)
                    if total > 0, item.amountMinor > 0 {
                        Text(percent).font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                    }
                    Spacer()
                    Text(Fmt.money(item.amountMinor, currency)).monospacedDigit()
                }
                GeometryReader { proxy in
                    Capsule().fill(Color.accentColor.opacity(0.35))
                        .frame(width: max(6, proxy.size.width * CGFloat(max(0, Double(item.amountMinor)) / Double(maxAmount))), height: 6)
                }
                .frame(height: 6)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var percent: String {
        let value = Double(item.amountMinor) / Double(total) * 100
        return value < 1 ? "<1%" : "\(Int(value.rounded()))%"
    }
}

/// 一个分类这个月的明细：大类下面的小类，和这个月记在这个分类上的每一笔
private struct CategoryStatsView: View {
    let item: MonthStats.CategoryTotal
    let type: EntryType
    let currency: CurrencyCode
    let from: Date?
    let to: Date?

    @Environment(LedgerStore.self) private var store
    @State private var rows: [RecordRow] = []

    var body: some View {
        List {
            Section {
                LabeledContent("合计", value: Fmt.money(item.amountMinor, currency))
                LabeledContent("笔数", value: "\(item.count) 笔")
            }
            if item.children.count > 1 || (item.children.first.map { $0.categoryID != item.categoryID } ?? false) {
                Section("小类") {
                    let maxAmount = max(1, item.children.map(\.amountMinor).max() ?? 1)
                    ForEach(item.children) { child in
                        CategoryTotalRow(
                            item: child.categoryID == item.categoryID ? MonthStats.CategoryTotal(
                                categoryID: child.categoryID, name: "不细分", symbol: child.symbol, amountMinor: child.amountMinor, count: child.count
                            ) : child,
                            currency: currency, maxAmount: maxAmount, total: item.amountMinor
                        )
                    }
                }
            }
            Section("每一笔") {
                ForEach(rows) { row in
                    NavigationLink {
                        RecordDetailView(recordID: row.id)
                    } label: {
                        RecordRowView(row: row)
                    }
                }
            }
        }
        .navigationTitle(item.name)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: store.revision) {
            let filter = RecordFilter(
                from: from, to: to, entryType: type, categoryID: item.categoryID ?? RecordFilter.uncategorized, feed: true, mergeFees: true
            )
            rows = await store.records(filter, after: nil, limit: 200).filter { $0.record.currency == currency }
        }
    }
}
