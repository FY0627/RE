import SwiftUI
import UIKit
import BKModel

/// 统计：选一段时间看（右上角的时间段胶囊，和卡片详情一样：全部、本周、本月、上月、今年、自定义）。
/// 下面用分段控件选「按币种」还是「按账户」（记住上次选的）：
/// 按币种是每个币种的支出、收入、结余，再按分类排（哪一类花得最多，点进去看小类和每一笔）；
/// 按账户是每个账户进出多少，点进去看这段时间的每一笔。
/// 转帐（自己的账户之间、还信用卡、存取现金）不算在收支里；退款从它所在的分类里减掉。多个币种分开统计，不换算。
/// 顶部一行和首页、资产页一样：左边大标题「统计」，右边时间段的玻璃胶囊。
struct StatsView: View {
    enum Grouping: String, CaseIterable, Identifiable {
        case currency
        case account
        var id: String { rawValue }
        var title: String { self == .currency ? "按币种" : "按账户" }
    }

    private struct LoadKey: Equatable {
        let period: RecordPeriod
        let revision: Int
    }

    @Environment(LedgerStore.self) private var store
    @AppStorage("stats.grouping") private var grouping = Grouping.currency
    @State private var period: RecordPeriod = .thisMonth
    @State private var choosingCustom = false
    @State private var stats: MonthStats?
    @State private var scrolledUnderBar = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("统计方式", selection: $grouping) {
                        ForEach(Grouping.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
                if let stats, !stats.currencies.isEmpty {
                    switch grouping {
                    case .currency:
                        ForEach(stats.currencies, id: \.currency) { totals in
                            currencySections(totals, isFirst: totals.currency == stats.currencies.first?.currency)
                        }
                    case .account:
                        accountSection(stats.accounts)
                    }
                } else if stats != nil {
                    Section {
                        ContentUnavailableView("这段时间还没有记录", systemImage: "chart.bar", description: Text(period.title))
                    }
                }
            }
            .listStyle(.insetGrouped)
            .trackingScrollUnderTopBar($scrolledUnderBar)
            .navigationTitle("统计")
            // 系统导航栏的大标题在按钮下面一行；藏起来，自己放一行（和资产页的标题行一样高、一样的位置）
            .navigationBarTitleDisplayMode(.inline)
            .toolbarVisibility(.hidden, for: .navigationBar)
            .safeAreaBar(edge: .top) {
                TitleBar(title: "统计", menu: .init(title: period.title) { periodMenu() })
                    .frame(height: GlassControls.size)
                    .padding(.horizontal, AppLayout.cardInset)
                    .padding(.top, 2)
                    .padding(.bottom, 6)
                    .background { TopBarBackdrop(visible: scrolledUnderBar) }
            }
            .sheet(isPresented: $choosingCustom) {
                CustomPeriodSheet(initial: period.customDates) { period = $0 }
            }
            .task(id: LoadKey(period: period, revision: store.revision)) {
                let range = period.range()
                stats = await store.stats(from: range.from, to: range.to)
            }
        }
    }

    /// 时间段胶囊的菜单：常用时间段，另起一组「自定义…」（选中时写自定义的日期）
    private func periodMenu() -> [UIMenuElement] {
        let presets: [UIMenuElement] = RecordPeriod.presets.map { option in
            UIAction(title: option.title, state: option == period ? .on : .off) { _ in period = option }
        }
        let custom = UIAction(title: period.isCustom ? period.title : "自定义…", state: period.isCustom ? .on : .off) { _ in
            choosingCustom = true
        }
        return presets + [UIMenu(options: .displayInline, children: [custom])]
    }

    /// 这段时间的范围（按收到通知的时间）
    private var range: (from: Date?, to: Date?) { period.range() }

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
            Text(isFirst ? "\(period.title) · \(t.currency.chineseName)" : t.currency.chineseName)
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

    /// 按账户：每个账户（多币种的按币种分开）进出多少，点进去看每一笔
    private func accountSection(_ totals: [MonthStats.AccountTotal]) -> some View {
        Section {
            ForEach(totals, id: \.self) { total in
                NavigationLink {
                    AccountStatsView(total: total, from: range.from, to: range.to)
                } label: {
                    accountRow(total)
                }
            }
        } header: {
            Text(period.title)
        } footer: {
            Text("进出都算，包括转帐和退款。")
        }
    }

    private func accountRow(_ total: MonthStats.AccountTotal) -> some View {
        let account = store.account(id: total.accountID)
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(account?.displayTitle ?? "已删除的账户").lineLimit(1)
                Text("\(total.currency.chineseName) · \(total.count) 笔").font(.footnote).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text("+" + Fmt.money(total.inflowMinor, total.currency)).foregroundStyle(AppTheme.income)
                Text("-" + Fmt.money(total.outflowMinor, total.currency))
            }
            .font(.subheadline.weight(.semibold))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .layoutPriority(1)
        }
        .accessibilityElement(children: .combine)
    }
}

/// 一个账户这段时间的每一笔（这个币种的）
private struct AccountStatsView: View {
    let total: MonthStats.AccountTotal
    let from: Date?
    let to: Date?

    @Environment(LedgerStore.self) private var store
    @State private var rows: [RecordRow] = []

    var body: some View {
        List {
            Section {
                LabeledContent("进", value: "+" + Fmt.money(total.inflowMinor, total.currency))
                LabeledContent("出", value: "-" + Fmt.money(total.outflowMinor, total.currency))
                LabeledContent("笔数", value: "\(total.count) 笔")
            }
            Section("每一笔") {
                ForEach(rows) { row in
                    NavigationLink {
                        RecordDetailView(recordID: row.id)
                    } label: {
                        RecordRowView(row: row, showAccount: false)
                    }
                }
            }
        }
        .navigationTitle(store.account(id: total.accountID)?.displayTitle ?? "已删除的账户")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: store.revision) {
            let filter = RecordFilter(accountID: total.accountID, from: from, to: to)
            rows = await store.records(filter, after: nil, limit: 200).filter { $0.record.currency == total.currency && $0.record.status == .posted }
        }
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

/// 一个分类这段时间的明细：大类下面的小类，和这段时间记在这个分类上的每一笔
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
