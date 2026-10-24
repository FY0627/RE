import Foundation
import BKModel
import BKDatabase

public enum BackendError: Error, Equatable, Sendable {
    case notFound
    case invalidAccount(AccountValidationError)
    /// 待处理项不允许确认（例如无法识别的通知），只能忽略
    case confirmationNotAllowed
    /// 选择的账户不在系统给出的候选里
    case accountNotACandidate
    case alreadyResolved
}

/// App 界面与 App Intent 共用的业务入口。
///
/// 所有方法都是 async，并在数据库的串行队列上执行；调用方即使在 MainActor 上，
/// 解析、匹配、去重和 SQL 也不会占用主线程。
public final class LedgerBackend: Sendable {
    let database: Database
    let clock: @Sendable () -> Date
    let calendar: Calendar
    let newID: @Sendable () -> String

    public init(database: Database, calendar: Calendar = .current, clock: @escaping @Sendable () -> Date = { Date() }, newID: @escaping @Sendable () -> String = { UUID().uuidString }) {
        self.database = database
        self.calendar = calendar
        self.clock = clock
        self.newID = newID
    }

    public static func open(at url: URL, calendar: Calendar = .current) throws -> LedgerBackend {
        LedgerBackend(database: try Database(path: url.path), calendar: calendar)
    }

    public static func inMemory(calendar: Calendar = .current, clock: @escaping @Sendable () -> Date = { Date() }) throws -> LedgerBackend {
        LedgerBackend(database: try Database.inMemory(), calendar: calendar, clock: clock)
    }

    private func engine(_ db: SQLiteConnection) -> IngestEngine {
        IngestEngine(db: db, now: clock(), calendar: calendar, newID: newID)
    }

    // MARK: 自动记账入口

    /// 处理一条短信 / 邮件。重复调用、并发调用都是幂等的。
    public func ingest(_ request: IngestRequest) async throws -> IngestResult {
        let now = clock()
        let calendar = calendar
        let newID = newID
        return try await database.write { db in
            try IngestEngine(db: db, now: now, calendar: calendar, newID: newID).run(request)
        }
    }

    // MARK: 账户

    public func accounts(includeArchived: Bool = false) async throws -> [Account] {
        try await database.read { try AccountDAO.all($0, includeArchived: includeArchived) }
    }

    public func addAccount(_ draft: AccountDraft) async throws -> Account {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let bankName = draft.bankName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bankName.isEmpty else { throw BackendError.invalidAccount(.emptyBank) }
        guard Account.isValidLast4(draft.last4) else { throw BackendError.invalidAccount(.invalidLast4) }
        let now = clock()
        let id = newID()
        let calendar = calendar
        let newID = newID
        return try await database.write { db in
            let existing = try AccountDAO.all(db)
            if existing.contains(where: { $0.last4 == draft.last4 && $0.bankName == bankName && $0.cardType == draft.cardType }) {
                throw BackendError.invalidAccount(.duplicateAccount)
            }
            let account = Account(
                id: id, name: name.isEmpty ? "\(bankName)\(draft.cardType.displayName)" : name, bankID: draft.bankID, bankName: bankName,
                last4: draft.last4, cardType: draft.cardType, currency: draft.currency, paletteID: draft.paletteID,
                sortOrder: try AccountDAO.nextSortOrder(db), createdAt: now
            )
            try AccountDAO.insert(db, account)
            // 账户添加之前收到的、因「没有匹配账户」而待处理的通知：现在能唯一匹配就入账
            try Self.rematchOpenPending(db, engine: IngestEngine(db: db, now: now, calendar: calendar, newID: newID))
            return account
        }
    }

    public func updateAppearance(accountID: String, paletteID: String) async throws {
        try await database.write { try AccountDAO.updateAppearance($0, id: accountID, paletteID: paletteID) }
    }

    /// 隐藏账户（保留其历史流水）。
    public func setArchived(accountID: String, archived: Bool) async throws {
        try await database.write { try AccountDAO.setArchived($0, id: accountID, archived: archived) }
    }

    public func automationStatus() async throws -> [String: AccountAutomationStatus] {
        try await database.read { db in
            Dictionary(uniqueKeysWithValues: try AccountDAO.automationStatus(db).map { ($0.accountID, $0) })
        }
    }

    // MARK: 流水

    public func records(accountID: String? = nil, before cursor: RecordCursor? = nil, limit: Int = 50) async throws -> [RecordRow] {
        try await database.read { try RecordDAO.page($0, accountID: accountID, before: cursor, limit: limit) }
    }

    public func recordCount(accountID: String? = nil) async throws -> Int {
        try await database.read { try RecordDAO.count($0, accountID: accountID) }
    }

    public func recordDetail(id: String) async throws -> RecordDetail {
        try await database.read { db in
            guard let row = try RecordDAO.findRow(db, id: id) else { throw BackendError.notFound }
            let evidence = try RecordDAO.evidence(db, recordID: id)
            var peer: RecordRow?
            if let group = row.record.transferGroupID {
                peer = try RecordDAO.inGroup(db, group: group).first { $0.id != id }.flatMap { try RecordDAO.findRow(db, id: $0.id) }
            }
            let related = try row.record.relatedRecordID.flatMap { try RecordDAO.findRow(db, id: $0) }
            return RecordDetail(row: row, evidence: evidence, transferPeer: peer, related: related)
        }
    }

    /// 账单唯一允许用户修改的业务字段：备注。
    public func updateNote(recordID: String, note: String) async throws {
        let trimmed = String(note.prefix(500))
        let updated = try await database.write { try RecordDAO.updateNote($0, id: recordID, note: trimmed) }
        if !updated { throw BackendError.notFound }
    }

    // MARK: 待处理

    public func openPendingItems() async throws -> [PendingItem] {
        try await database.read { try PendingDAO.open($0) }
    }

    public func pendingCount() async throws -> Int {
        try await database.read { try PendingDAO.openCount($0) }
    }

    /// 确认系统给出的候选。不能借此修改金额、方向、时间等字段。
    public func confirmPending(id: String, accountID: String) async throws {
        let now = clock()
        let calendar = calendar
        let newID = newID
        try await database.write { db in
            guard let item = try PendingDAO.find(db, id: id) else { throw BackendError.notFound }
            guard item.status == .open else { throw BackendError.alreadyResolved }
            guard item.reason.allowsConfirmation, let draft = item.draft else { throw BackendError.confirmationNotAllowed }
            let accounts = try AccountDAO.all(db)
            guard let account = accounts.first(where: { $0.id == accountID }) else { throw BackendError.notFound }
            let allowed = item.candidateAccountIDs.isEmpty
                ? (draft.cardTail != nil && account.last4 == draft.cardTail)
                : item.candidateAccountIDs.contains(accountID)
            guard allowed else { throw BackendError.accountNotACandidate }
            guard let meta = try IngestDAO.meta(db, id: item.ingestID) else { throw BackendError.notFound }
            let engine = IngestEngine(db: db, now: now, calendar: calendar, newID: newID)
            let outcome = try engine.commit(
                draft, meta: .init(ingestID: item.ingestID, source: meta.source, receivedAt: meta.receivedAt, processedAt: meta.processedAt),
                boundAccountID: nil, accounts: accounts, forcedAccount: account, duplicateCheck: false,
                forcedDedupeKey: item.reason == .possibleDuplicate ? "c|" + item.id : nil
            )
            if case .pending = outcome { throw BackendError.confirmationNotAllowed }
            _ = try PendingDAO.resolve(db, id: id, status: .confirmed, at: now)
        }
    }

    public func ignorePending(id: String) async throws {
        let now = clock()
        try await database.write { db in
            guard let item = try PendingDAO.find(db, id: id) else { throw BackendError.notFound }
            guard try PendingDAO.resolve(db, id: id, status: .ignored, at: now) else { throw BackendError.alreadyResolved }
            // 用户确认是重复：把这条通知记为原流水的另一份来源证据
            if item.reason == .possibleDuplicate, let original = item.duplicateOfRecordID {
                try RecordDAO.addEvidence(db, recordID: original, ingestID: item.ingestID, source: item.source, at: now)
            }
        }
    }

    static func rematchOpenPending(_ db: SQLiteConnection, engine: IngestEngine) throws {
        let accounts = try AccountDAO.all(db)
        for item in try PendingDAO.open(db) where item.reason == .noMatchingAccount {
            guard let draft = item.draft, let meta = try IngestDAO.meta(db, id: item.ingestID) else { continue }
            guard case .matched = AccountMatcher.match(tail: draft.cardTail, bankHint: draft.bankHint, boundAccountID: nil, accounts: accounts) else { continue }
            let outcome = try engine.commit(
                draft, meta: .init(ingestID: item.ingestID, source: meta.source, receivedAt: meta.receivedAt, processedAt: meta.processedAt),
                boundAccountID: nil, accounts: accounts, forcedAccount: nil, duplicateCheck: true
            )
            switch outcome {
            case .recorded, .merged: _ = try PendingDAO.resolve(db, id: item.id, status: .confirmed, at: engine.now)
            case .pending: continue
            }
        }
    }

    public func ingestLog(limit: Int = 50) async throws -> [IngestLogEntry] {
        try await database.read { try IngestDAO.recent($0, limit: limit) }
    }

    // MARK: 余额

    public func balanceSummaries() async throws -> [String: AccountBalanceSummary] {
        let calendar = calendar
        return try await database.read { db in
            var result: [String: AccountBalanceSummary] = [:]
            for account in try AccountDAO.all(db, includeArchived: true) {
                result[account.id] = try Self.balanceSummary(db, account: account, calendar: calendar)
            }
            return result
        }
    }

    static func balanceSummary(_ db: SQLiteConnection, account: Account, calendar: Calendar) throws -> AccountBalanceSummary {
        guard let base = try BalanceDAO.latest(db, accountID: account.id) else {
            return AccountBalanceSummary(accountID: account.id, bankReported: nil, ledgerDerivedMinor: nil, recordsAfterBase: 0)
        }
        let engine = IngestEngine(db: db, now: Date(), calendar: calendar, newID: { "" })
        var total = base.amountMinor
        var count = 0
        for record in try RecordDAO.postedAfter(db, accountID: account.id, currency: base.currency) where record.id != base.recordID {
            let key = engine.orderKey(time: record.transactionTime, fallback: record.effectiveAt)
            guard key > base.orderKey else { continue }
            total += record.direction == .inflow ? record.amountMinor : -record.amountMinor
            count += 1
        }
        return AccountBalanceSummary(accountID: account.id, bankReported: base, ledgerDerivedMinor: total, recordsAfterBase: count)
    }

    // MARK: 统计

    public func monthStats(year: Int, month: Int) async throws -> MonthStats {
        let calendar = calendar
        guard let start = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
              let end = calendar.date(byAdding: .month, value: 1, to: start) else { throw BackendError.notFound }
        return try await database.read { db in
            StatsCalculator.month(year: year, month: month, records: try RecordDAO.inRange(db, from: start, to: end))
        }
    }

    // MARK: 设置与清理

    public func rawRetentionDays() async throws -> Int {
        try await database.read { try SettingsDAO.get($0, IngestEngine.retentionKey).flatMap(Int.init) ?? IngestEngine.defaultRetentionDays }
    }

    public func setRawRetentionDays(_ days: Int) async throws {
        let clamped = min(365, max(1, days))
        try await database.write { try SettingsDAO.set($0, IngestEngine.retentionKey, String(clamped)) }
    }

    /// 清空到期的原始正文。待处理中的正文保留到处理完成。
    @discardableResult
    public func purgeExpiredRawContent() async throws -> Int {
        let now = clock()
        return try await database.write { try IngestDAO.purgeRaw($0, now: now) }
    }
}

enum StatsCalculator {
    static func month(year: Int, month: Int, records: [LedgerRecord]) -> MonthStats {
        var byCurrency: [CurrencyCode: MonthStats.CurrencyTotals] = [:]
        var byKind: [CurrencyCode: [String: MonthStats.KindTotal]] = [:]
        var byAccount: [String: MonthStats.AccountTotal] = [:]
        var holds = 0, failed = 0
        for r in records {
            switch r.status {
            case .hold, .holdReleased: holds += 1; continue
            case .failed: failed += 1; continue
            case .posted: break
            }
            var totals = byCurrency[r.currency] ?? .init(currency: r.currency, expenseMinor: 0, incomeMinor: 0, refundMinor: 0, internalTransferMinor: 0, repaymentMinor: 0, recordCount: 0, byKind: [])
            totals.recordCount += 1
            if r.isInternalTransfer {
                if r.direction == .outflow { totals.internalTransferMinor += r.amountMinor }
            } else if r.kind == .repayment {
                totals.repaymentMinor += r.amountMinor
            } else if r.direction == .outflow {
                totals.expenseMinor += r.amountMinor
            } else if r.kind == .refund || r.kind == .reversal {
                totals.refundMinor += r.amountMinor
            } else {
                totals.incomeMinor += r.amountMinor
            }
            byCurrency[r.currency] = totals

            let kindKey = r.kind.rawValue + "|" + r.direction.rawValue
            var kindTotal = byKind[r.currency]?[kindKey] ?? .init(kind: r.kind, direction: r.direction, amountMinor: 0, count: 0)
            kindTotal.amountMinor += r.amountMinor
            kindTotal.count += 1
            byKind[r.currency, default: [:]][kindKey] = kindTotal

            let accountKey = r.accountID + "|" + r.currency.rawValue
            var accountTotal = byAccount[accountKey] ?? .init(accountID: r.accountID, currency: r.currency, inflowMinor: 0, outflowMinor: 0, count: 0)
            if r.direction == .inflow { accountTotal.inflowMinor += r.amountMinor } else { accountTotal.outflowMinor += r.amountMinor }
            accountTotal.count += 1
            byAccount[accountKey] = accountTotal
        }
        let currencies = byCurrency.values.map { totals -> MonthStats.CurrencyTotals in
            var t = totals
            t.byKind = (byKind[t.currency] ?? [:]).values.sorted { $0.amountMinor > $1.amountMinor }
            return t
        }.sorted { $0.recordCount > $1.recordCount }
        return MonthStats(year: year, month: month, currencies: currencies, accounts: byAccount.values.sorted { $0.outflowMinor + $0.inflowMinor > $1.outflowMinor + $1.inflowMinor }, holdCount: holds, failedCount: failed)
    }
}
