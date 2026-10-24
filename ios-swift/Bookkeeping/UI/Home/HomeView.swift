import SwiftUI
import BKModel

/// 首页：本月概览 + 全部账户的资金流水（按日期分组，分页加载）。系统导航栏 + 分组列表。
struct HomeView: View {
    let openPending: () -> Void
    @Environment(LedgerStore.self) private var store

    var body: some View {
        let groups = Self.group(store.homeRows)
        NavigationStack {
            List {
                Section {
                    summary
                } header: {
                    Text(Self.monthTitle)
                }
                if store.pendingCount > 0 {
                    Section { pendingBanner }
                }
                if store.homeRows.isEmpty {
                    Section("资金流水") { emptyState }
                } else {
                    ForEach(groups, id: \.day) { group in
                        Section(group.title) {
                            ForEach(group.rows) { row in
                                NavigationLink(value: row.id) { RecordRowView(row: row) }
                                    .onAppear {
                                        if row.id == store.homeRows.last?.id { Task { await store.loadMoreHome() } }
                                    }
                            }
                        }
                    }
                    if store.homeHasMore {
                        ProgressView().frame(maxWidth: .infinity)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("日常记账")
            .navigationDestination(for: String.self) { id in RecordDetailView(recordID: id) }
            .refreshable { await store.refresh() }
        }
    }

    private static var monthTitle: String {
        let c = Calendar.current.dateComponents([.year, .month], from: Date())
        return Fmt.monthTitle(year: c.year ?? 0, month: c.month ?? 0)
    }

    @ViewBuilder
    private var summary: some View {
        let currencies = store.monthStats?.currencies ?? []
        VStack(alignment: .leading, spacing: 0) {
            Text("本月支出").font(.subheadline).foregroundStyle(.secondary)
            if let main = currencies.first {
                Text(Fmt.money(main.expenseMinor, main.currency))
                    .font(.system(.largeTitle, design: .rounded).weight(.bold))
                    .monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.6)
                    .padding(.top, 2)
                HStack(alignment: .top, spacing: 20) {
                    stat("本月收入", Fmt.money(main.incomeMinor, main.currency))
                    stat("退款/冲正", Fmt.money(main.refundMinor, main.currency))
                    stat("流水", "\(main.recordCount) 笔")
                }
                .padding(.top, 12)
                if currencies.count > 1 {
                    Text(currencies.dropFirst().map { "\($0.currency.rawValue) 支出 \(Fmt.money($0.expenseMinor, $0.currency))" }.joined(separator: " · "))
                        .font(.footnote).foregroundStyle(.secondary).padding(.top, 10)
                }
            } else {
                Text("—").font(.system(.largeTitle, design: .rounded).weight(.bold)).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.footnote).foregroundStyle(.secondary)
            Text(value).font(.headline).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
        }
    }

    private var pendingBanner: some View {
        Button(action: openPending) {
            HStack(spacing: 12) {
                Image(systemName: "tray.full").font(.title3).foregroundStyle(AppTheme.debt)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(store.pendingCount) 条通知待处理").font(.headline).foregroundStyle(.primary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 4)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("还没有流水", systemImage: "list.bullet.rectangle")
        } description: {
            Text("添加银行卡并设置自动记账后，流水会出现在这里。")
        }
    }

    struct DayGroup {
        let day: Date
        let title: String
        let rows: [RecordRow]
    }

    static func group(_ rows: [RecordRow]) -> [DayGroup] {
        let calendar = Calendar.current
        let now = Date()
        var groups: [DayGroup] = []
        var currentDay: Date?
        var bucket: [RecordRow] = []
        for row in rows {
            let day = calendar.startOfDay(for: row.record.effectiveAt)
            if day != currentDay, let currentDay {
                groups.append(DayGroup(day: currentDay, title: Fmt.day(currentDay, now: now), rows: bucket))
                bucket = []
            }
            currentDay = day
            bucket.append(row)
        }
        if let currentDay { groups.append(DayGroup(day: currentDay, title: Fmt.day(currentDay, now: now), rows: bucket)) }
        return groups
    }
}
