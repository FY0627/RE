import SwiftUI
import BKModel

/// 首页：本月概览 + 全部账户的资金流水（按日期分组，分页加载）。分组列表。
///
/// 顶部一行和资产页一样：左边大标题「日常记账」，右边圆形的玻璃搜索按钮（不用系统导航栏，系统的大标题和按钮不在同一行）。
/// 点搜索按钮，按钮像液态玻璃一样展开成搜索框，右边分出圆形的关闭按钮；可以按交易对方、备注、金额、卡号尾号、银行查流水，
/// 还能只看支出或收入。删除流水在流水详情里。
struct HomeView: View {
    let openPending: () -> Void
    @Environment(LedgerStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var searching = false
    @FocusState private var searchFocused: Bool
    @Namespace private var glass
    @State private var query = ""
    @State private var scope: SearchScope = .all
    @State private var results: [RecordRow] = []
    @State private var resultsHaveMore = false
    /// 已经查过的条件：结果对应这些条件时才显示「没有结果」
    @State private var searched: SearchKey?
    @State private var loadingMore = false

    enum SearchScope: Hashable, CaseIterable {
        case all, outflow, inflow

        var title: String {
            switch self {
            case .all: "全部"
            case .outflow: "支出"
            case .inflow: "收入"
            }
        }

        var direction: FlowDirection? {
            switch self {
            case .all: nil
            case .outflow: .outflow
            case .inflow: .inflow
            }
        }
    }

    struct SearchKey: Hashable {
        var text: String
        var scope: SearchScope
        /// 数据变了（删除、修改、新流水）重新查
        var revision: Int
    }

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            List {
                if trimmedQuery.isEmpty {
                    feed
                } else {
                    searchResults
                }
            }
            .listStyle(.insetGrouped)
            .scrollDismissesKeyboard(.immediately)
            .navigationTitle("日常记账")
            .toolbarVisibility(.hidden, for: .navigationBar)
            // 顶部一行固定在上面，列表从它下面滚过时系统加上边缘的渐隐效果
            .safeAreaBar(edge: .top) { topBar }
            .navigationDestination(for: String.self) { id in RecordDetailView(recordID: id) }
            .refreshable { await store.refresh() }
            .task(id: SearchKey(text: trimmedQuery, scope: scope, revision: store.revision)) {
                await search(SearchKey(text: trimmedQuery, scope: scope, revision: store.revision))
            }
        }
    }

    // MARK: 顶部

    /// 和资产页的标题行一样高、一样的位置：44pt 高，离状态栏 2pt
    private var topBar: some View {
        VStack(spacing: 10) {
            GlassEffectContainer(spacing: 16) {
                HStack(spacing: 10) {
                    if searching {
                        searchField
                            .glassEffect(.regular.interactive(), in: Capsule())
                            .glassEffectID("search", in: glass)
                        Button(action: closeSearch) { ToolbarIcon("xmark") }
                            .buttonStyle(.plain)
                            .glassEffect(.regular.interactive(), in: Circle())
                            .glassEffectID("close", in: glass)
                            .accessibilityLabel("关闭搜索")
                    } else {
                        Text("日常记账")
                            .font(.largeTitle.weight(.bold))
                            .lineLimit(1)
                            .padding(.horizontal, 4)
                            .accessibilityAddTraits(.isHeader)
                            .transition(.opacity)
                        Spacer(minLength: 0)
                        Button(action: openSearch) { ToolbarIcon("magnifyingglass") }
                            .buttonStyle(.plain)
                            .glassEffect(.regular.interactive(), in: Circle())
                            .glassEffectID("search", in: glass)
                            .accessibilityLabel("搜索流水")
                    }
                }
                .frame(height: 44)
            }
            if searching {
                Picker("范围", selection: $scope) {
                    ForEach(SearchScope.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, AppLayout.cardInset)
        .padding(.top, 2)
        .padding(.bottom, 6)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Color.secondary)
            TextField("商户、备注、金额、尾号", text: $query)
                .focused($searchFocused)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Color.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除")
            }
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, minHeight: 44, maxHeight: 44)
    }

    private var searchAnimation: Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.42, dampingFraction: 0.72)
    }

    private func openSearch() {
        withAnimation(searchAnimation) { searching = true }
        // 搜索框出现后再弹出键盘
        Task { @MainActor in searchFocused = true }
    }

    private func closeSearch() {
        searchFocused = false
        query = ""
        scope = .all
        withAnimation(searchAnimation) { searching = false }
    }

    // MARK: 流水

    @ViewBuilder
    private var feed: some View {
        Section {
            summary
        } header: {
            Text(Self.monthTitle)
        }
        if store.pendingCount + store.transferConfirmCount > 0 {
            Section { pendingBanner }
        }
        if store.homeRows.isEmpty {
            Section("资金流水") { emptyState }
        } else {
            ForEach(Self.group(store.homeRows), id: \.day) { group in
                Section(group.title) {
                    ForEach(group.rows) { row in
                        recordLink(row)
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

    private func recordLink(_ row: RecordRow) -> some View {
        NavigationLink(value: row.id) { RecordRowView(row: row) }
    }

    // MARK: 搜索

    @ViewBuilder
    private var searchResults: some View {
        if results.isEmpty {
            if searched?.text == trimmedQuery, searched?.scope == scope {
                ContentUnavailableView.search(text: trimmedQuery)
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        } else {
            ForEach(Self.group(results), id: \.day) { group in
                Section(group.title) {
                    ForEach(group.rows) { row in
                        recordLink(row)
                            .onAppear {
                                if row.id == results.last?.id { Task { await loadMoreResults() } }
                            }
                    }
                }
            }
            if resultsHaveMore {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
    }

    private func search(_ key: SearchKey) async {
        guard !key.text.isEmpty else {
            results = []
            resultsHaveMore = false
            searched = nil
            return
        }
        // 边打字边查：停下来一会儿再查
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        let rows = await store.records(RecordFilter(direction: key.scope.direction, text: key.text), after: nil, limit: LedgerStore.pageSize)
        guard !Task.isCancelled else { return }
        results = rows
        resultsHaveMore = rows.count == LedgerStore.pageSize
        searched = key
    }

    private func loadMoreResults() async {
        guard resultsHaveMore, !loadingMore, let key = searched, let last = results.last else { return }
        loadingMore = true
        defer { loadingMore = false }
        let page = await store.records(RecordFilter(direction: key.scope.direction, text: key.text), after: last, limit: LedgerStore.pageSize)
        guard searched == key else { return }
        let known = Set(results.map(\.id))
        results += page.filter { !known.contains($0.id) }
        resultsHaveMore = page.count == LedgerStore.pageSize
    }

    // MARK: 概览

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

    private var pendingTitle: String {
        var parts: [String] = []
        if store.pendingCount > 0 { parts.append("\(store.pendingCount) 条通知待处理") }
        if store.transferConfirmCount > 0 { parts.append("\(store.transferConfirmCount) 笔转账待确认") }
        return parts.joined(separator: "，")
    }

    private var pendingBanner: some View {
        Button(action: openPending) {
            HStack(spacing: 12) {
                Image(systemName: "tray.full").font(.title3).foregroundStyle(AppTheme.debt)
                VStack(alignment: .leading, spacing: 2) {
                    Text(pendingTitle).font(.headline).foregroundStyle(.primary)
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
