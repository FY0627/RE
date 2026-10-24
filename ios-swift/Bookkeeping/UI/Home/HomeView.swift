import SwiftUI
import BKModel

/// 首页：全部账户的资金流水，按日期分组，分页加载。
struct HomeView: View {
    let openPending: () -> Void
    @Environment(LedgerStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    @State private var selected: RecordRow?

    var body: some View {
        let palette = Theme(scheme: scheme)
        let groups = Self.group(store.homeRows)
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 0) {
                header(palette)
                summary(palette).padding(.top, 18)
                if store.pendingCount > 0 {
                    pendingBanner(palette).padding(.top, 14)
                }
                Text("资金流水").font(.system(size: 15, weight: .semibold)).foregroundStyle(palette.ink)
                    .padding(.top, 22).padding(.bottom, 4)
                if store.homeRows.isEmpty {
                    emptyState(palette)
                } else {
                    ForEach(groups, id: \.day) { group in
                        Text(group.title)
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(palette.muted)
                            .padding(.top, 14).padding(.bottom, 6).padding(.leading, 4)
                        ForEach(group.rows) { row in
                            Button { selected = row } label: { RecordRowView(row: row) }
                                .buttonStyle(.plain)
                                .padding(.bottom, 8)
                                .onAppear {
                                    if row.id == store.homeRows.last?.id { Task { await store.loadMoreHome() } }
                                }
                        }
                    }
                    if store.homeHasMore {
                        ProgressView().frame(maxWidth: .infinity).padding()
                    }
                }
                Color.clear.frame(height: 110)
            }
            .padding(.horizontal, 16)
        }
        .scrollIndicators(.hidden)
        .refreshable { await store.refresh() }
        .sheet(item: $selected) { row in RecordDetailView(recordID: row.id) }
    }

    private func header(_ palette: Theme) -> some View {
        let now = Date()
        let c = Calendar.current.dateComponents([.year, .month], from: now)
        return VStack(alignment: .leading, spacing: 2) {
            Text("日常记账").font(.system(size: 24, weight: .bold)).foregroundStyle(palette.ink)
            Text("本地账本 · \(Fmt.monthTitle(year: c.year ?? 0, month: c.month ?? 0))").font(.system(size: 11)).foregroundStyle(palette.muted)
        }
        .padding(.top, 12)
    }

    @ViewBuilder
    private func summary(_ palette: Theme) -> some View {
        let currencies = store.monthStats?.currencies ?? []
        if let main = currencies.first {
            VStack(alignment: .leading, spacing: 0) {
                Text("本月支出").font(.system(size: 12)).foregroundStyle(palette.muted)
                Text(Fmt.money(main.expenseMinor, main.currency))
                    .font(.system(size: 38, weight: .bold)).foregroundStyle(palette.ink)
                    .lineLimit(1).minimumScaleFactor(0.6)
                    .padding(.top, 4)
                HStack(spacing: 24) {
                    stat("本月收入", Fmt.money(main.incomeMinor, main.currency), palette)
                    stat("退款/冲正", Fmt.money(main.refundMinor, main.currency), palette)
                    stat("流水", "\(main.recordCount) 笔", palette)
                }
                .padding(.top, 14)
                if currencies.count > 1 {
                    Text(currencies.dropFirst().map { "\($0.currency.rawValue) 支出 \(Fmt.money($0.expenseMinor, $0.currency))" }.joined(separator: " · "))
                        .font(.system(size: 11)).foregroundStyle(palette.muted).padding(.top, 10)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text("本月支出").font(.system(size: 12)).foregroundStyle(palette.muted)
                Text("—").font(.system(size: 38, weight: .bold)).foregroundStyle(palette.muted)
            }
        }
    }

    private func stat(_ title: String, _ value: String, _ palette: Theme) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 11)).foregroundStyle(palette.muted)
            Text(value).font(.system(size: 15, weight: .semibold)).foregroundStyle(palette.ink).lineLimit(1)
        }
    }

    private func pendingBanner(_ palette: Theme) -> some View {
        Button(action: openPending) {
            HStack(spacing: 10) {
                Image(systemName: "tray.full").font(.system(size: 16)).foregroundStyle(AppTheme.debt)
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(store.pendingCount) 条通知待处理").font(.system(size: 13, weight: .semibold)).foregroundStyle(palette.ink)
                    Text("信息有歧义或不完整，没有自动入账").font(.system(size: 11)).foregroundStyle(palette.muted)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(palette.muted)
            }
            .padding(14)
            .background(palette.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func emptyState(_ palette: Theme) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "list.bullet.rectangle").font(.system(size: 30)).foregroundStyle(palette.muted)
            Text("还没有流水").font(.system(size: 15, weight: .semibold)).foregroundStyle(palette.ink)
            Text("到「资产」添加银行卡，在卡片详情里点「设置自动记账」。之后收到的银行短信或邮件会在后台记入这里。")
                .font(.system(size: 12)).foregroundStyle(palette.muted).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .padding(.horizontal, 20)
        .background(palette.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.top, 8)
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
