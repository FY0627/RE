import Foundation
import Observation
import BKBackend
import BKModel

/// 界面状态。只在 MainActor 上保存结果；所有查询和写入都由 `LedgerBackend`
/// 在数据库队列上执行，主线程只负责接收结果。
@MainActor
@Observable
final class LedgerStore {
    enum LoadState: Equatable {
        case loading
        case ready
        case failed(String)
    }

    private(set) var state: LoadState = .loading
    private(set) var accounts: [Account] = []
    private(set) var balances: [String: AccountBalanceSummary] = [:]
    private(set) var automation: [String: AccountAutomationStatus] = [:]
    private(set) var pendingCount = 0
    private(set) var homeRows: [RecordRow] = []
    private(set) var homeHasMore = false
    private(set) var monthStats: MonthStats?
    /// 每次数据变化 +1，详情页等据此重新加载自己的分页数据
    private(set) var revision = 0

    private var backend: LedgerBackend?
    private var loadingMore = false
    private var refreshTask: Task<Void, Never>?
    static let pageSize = 60

    func start() async {
        guard backend == nil else { return }
        do {
            // 打开数据库（含迁移）放在后台线程
            backend = try await Task.detached(priority: .userInitiated) { try AppServices.shared.backend() }.value
            await refresh()
            _ = try? await backend?.purgeExpiredRawContent()
        } catch {
            state = .failed((error as? LocalizedError)?.errorDescription ?? String(describing: error))
        }
    }

    func retryStart() async {
        state = .loading
        backend = nil
        await start()
    }

    /// 合并短时间内的多次刷新请求（例如自动化连续写入）。
    func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    func refresh() async {
        guard let backend else { return }
        let signpost = AppServices.signposter.beginInterval("StoreRefresh")
        defer { AppServices.signposter.endInterval("StoreRefresh", signpost) }
        do {
            let now = Date()
            let year = Calendar.current.component(.year, from: now)
            let month = Calendar.current.component(.month, from: now)
            async let accounts = backend.accounts()
            async let balances = backend.balanceSummaries()
            async let automation = backend.automationStatus()
            async let pending = backend.pendingCount()
            async let rows = backend.records(limit: Self.pageSize)
            async let stats = backend.monthStats(year: year, month: month)
            let (a, b, au, p, r, s) = try await (accounts, balances, automation, pending, rows, stats)
            self.accounts = a
            self.balances = b
            self.automation = au
            self.pendingCount = p
            self.homeRows = r
            self.homeHasMore = r.count == Self.pageSize
            self.monthStats = s
            self.revision += 1
            state = .ready
        } catch {
            state = .failed(String(describing: error))
        }
    }

    func loadMoreHome() async {
        guard let backend, homeHasMore, !loadingMore, let last = homeRows.last else { return }
        loadingMore = true
        defer { loadingMore = false }
        let cursor = RecordCursor(effectiveAt: last.record.effectiveAt, id: last.id)
        if let page = try? await backend.records(before: cursor, limit: Self.pageSize) {
            homeRows += page
            homeHasMore = page.count == Self.pageSize
        }
    }

    func records(accountID: String, after last: RecordRow?) async -> [RecordRow] {
        guard let backend else { return [] }
        let cursor = last.map { RecordCursor(effectiveAt: $0.record.effectiveAt, id: $0.id) }
        return (try? await backend.records(accountID: accountID, before: cursor, limit: 40)) ?? []
    }

    func recordCount(accountID: String) async -> Int {
        (try? await backend?.recordCount(accountID: accountID)) ?? 0
    }

    func addAccount(_ draft: AccountDraft) async throws -> Account {
        guard let backend else { throw BackendError.notFound }
        let account = try await backend.addAccount(draft)
        await refresh()
        return account
    }

    func updateAppearance(accountID: String, paletteID: String) async {
        try? await backend?.updateAppearance(accountID: accountID, paletteID: paletteID)
        await refresh()
    }

    func setArchived(accountID: String, archived: Bool) async {
        try? await backend?.setArchived(accountID: accountID, archived: archived)
        await refresh()
    }

    func detail(recordID: String) async -> RecordDetail? {
        try? await backend?.recordDetail(id: recordID)
    }

    func updateNote(recordID: String, note: String) async throws {
        guard let backend else { return }
        try await backend.updateNote(recordID: recordID, note: note)
        if let index = homeRows.firstIndex(where: { $0.id == recordID }) { homeRows[index].record.note = note }
        revision += 1
    }

    func pendingItems() async -> [PendingItem] {
        (try? await backend?.openPendingItems()) ?? []
    }

    func confirmPending(id: String, accountID: String) async throws {
        try await backend?.confirmPending(id: id, accountID: accountID)
        await refresh()
    }

    func ignorePending(id: String) async throws {
        try await backend?.ignorePending(id: id)
        await refresh()
    }

    func ingestLog() async -> [IngestLogEntry] {
        (try? await backend?.ingestLog(limit: 100)) ?? []
    }

    func stats(year: Int, month: Int) async -> MonthStats? {
        try? await backend?.monthStats(year: year, month: month)
    }

    func retentionDays() async -> Int {
        (try? await backend?.rawRetentionDays()) ?? 30
    }

    func setRetentionDays(_ days: Int) async {
        try? await backend?.setRawRetentionDays(days)
        _ = try? await backend?.purgeExpiredRawContent()
    }

    func account(id: String) -> Account? { accounts.first { $0.id == id } }
}
