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
    /// 使用中的卡（资产页上方的卡包、净资产、待处理账单的账户选择）
    private(set) var accounts: [Account] = []
    /// 已停用的卡：不参与自动记账和净资产，在资产页最下方以灰色卡包显示
    private(set) var archivedAccounts: [Account] = []
    /// 全部卡片，按添加顺序
    private(set) var allAccounts: [Account] = []
    private(set) var balances: [String: AccountBalances] = [:]
    private(set) var automation: [String: AccountAutomationStatus] = [:]
    private(set) var pendingCount = 0
    /// 没配对到自己另一张卡、待确认对方的转账
    private(set) var transferConfirmCount = 0
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
            async let accounts = backend.accounts(includeArchived: true)
            async let balances = backend.balanceSummaries()
            async let automation = backend.automationStatus()
            async let pending = backend.pendingCount()
            async let transfers = backend.unconfirmedTransferCount()
            async let rows = backend.records(limit: Self.pageSize)
            async let stats = backend.monthStats(year: year, month: month)
            let (a, b, au, p, r, s, t) = try await (accounts, balances, automation, pending, rows, stats, transfers)
            self.allAccounts = a
            self.accounts = a.filter { !$0.archived }
            self.archivedAccounts = a.filter(\.archived)
            self.balances = b
            self.automation = au
            self.pendingCount = p
            self.transferConfirmCount = t
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

    func updateCardFace(accountID: String, paletteID: String, face: CardFace) async throws {
        guard let backend else { throw BackendError.notFound }
        try await backend.updateCardFace(accountID: accountID, paletteID: paletteID, face: face)
        await refresh()
    }

    func updateCardInfo(accountID: String, name: String, cardNumber: String?, accountNumber: String?, extraCurrencies: [CurrencyCode]?) async throws {
        guard let backend else { throw BackendError.notFound }
        try await backend.updateCardInfo(accountID: accountID, name: name, cardNumber: cardNumber, extraCurrencies: extraCurrencies)
        try await backend.updateAccountNumber(accountID: accountID, accountNumber: accountNumber)
        await refresh()
    }

    func setOpeningBalance(accountID: String, currency: CurrencyCode, amountMinor: Int64?) async throws {
        guard let backend else { throw BackendError.notFound }
        try await backend.setOpeningBalance(accountID: accountID, currency: currency, amountMinor: amountMinor)
        await refresh()
    }

    /// 至少有一张卡收到过自动输入：说明自动化已经在工作，新卡不需要再设置
    var automationVerified: Bool { automation.values.contains { $0.lastSuccessAt != nil } }

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

    func unconfirmedTransfers() async -> [RecordRow] {
        (try? await backend?.unconfirmedTransfers()) ?? []
    }

    func setTransferParty(recordID: String, party: TransferParty?) async throws {
        try await backend?.setTransferParty(recordID: recordID, party: party)
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

    /// 包括已停用的卡
    func account(id: String) -> Account? { allAccounts.first { $0.id == id } }
}
