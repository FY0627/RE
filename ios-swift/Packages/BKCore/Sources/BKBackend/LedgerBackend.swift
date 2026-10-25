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
            let extras = Account.normalizedExtras(draft.extraCurrencies, primary: draft.currency)
            var openings: [OpeningBalance] = []
            if let minor = draft.openingBalanceMinor { openings.append(OpeningBalance(currency: draft.currency, amountMinor: minor, at: now)) }
            for currency in extras {
                if let minor = draft.extraOpeningBalances[currency] { openings.append(OpeningBalance(currency: currency, amountMinor: minor, at: now)) }
            }
            let account = Account(
                id: id, name: name.isEmpty ? "\(bankName)\(draft.cardType.displayName)" : name, bankID: draft.bankID, bankName: bankName,
                last4: draft.last4, cardType: draft.cardType, currency: draft.currency, extraCurrencies: extras, paletteID: draft.paletteID,
                sortOrder: try AccountDAO.nextSortOrder(db), createdAt: now, openingBalances: openings
            )
            try AccountDAO.insert(db, account)
            // 账户添加之前收到的、因「没有匹配账户」而待处理的通知：现在能唯一匹配就入账
            try Self.rematchOpenPending(db, engine: IngestEngine(db: db, now: now, calendar: calendar, newID: newID))
            return account
        }
    }

    /// 卡面：配色、背景图标识、文字颜色和大小。只影响显示，不影响账户匹配。
    public func updateCardFace(accountID: String, paletteID: String, face: CardFace) async throws {
        var stored = face
        stored.textScale = min(CardFace.textScaleRange.upperBound, max(CardFace.textScaleRange.lowerBound, face.textScale))
        let face = stored
        let updated = try await database.write { try AccountDAO.updateFace($0, id: accountID, paletteID: paletteID, face: face) }
        if !updated { throw BackendError.notFound }
    }

    /// 卡片信息里可改的字段：账户名称（留空恢复默认名称）、选填的完整卡号（nil 或空串清除）、
    /// 多币种账户的其他币种（nil 表示不修改）。银行、尾号、卡类型、主币种决定自动记账的匹配，不在这里修改。
    public func updateCardInfo(accountID: String, name: String, cardNumber: String?, extraCurrencies: [CurrencyCode]? = nil) async throws {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawNumber = cardNumber?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var number: String?
        if !rawNumber.isEmpty {
            guard let normalized = Account.normalizedCardNumber(rawNumber) else { throw BackendError.invalidAccount(.invalidCardNumber) }
            number = normalized
        }
        let cardNumber = number
        try await database.write { db in
            guard let account = try AccountDAO.find(db, id: accountID) else { throw BackendError.notFound }
            if let cardNumber, !cardNumber.hasSuffix(account.last4) { throw BackendError.invalidAccount(.invalidCardNumber) }
            let name = trimmedName.isEmpty ? "\(account.bankName)\(account.cardType.displayName)" : trimmedName
            try AccountDAO.updateInfo(db, id: accountID, name: name, cardNumber: cardNumber)
            if let extraCurrencies {
                let extras = Account.normalizedExtras(extraCurrencies, primary: account.currency)
                try AccountDAO.updateExtraCurrencies(db, id: accountID, primary: account.currency, extras: extras)
            }
        }
    }

    /// 设置这张卡某个币种「现在」的余额（最小货币单位）；传 nil 清除。不指定币种时为主币种。
    /// 之后到达的同币种流水会加到这个数上；更早的流水和银行通知余额不受影响。
    public func setOpeningBalance(accountID: String, currency: CurrencyCode? = nil, amountMinor: Int64?) async throws {
        let now = clock()
        let updated = try await database.write { db -> Bool in
            guard let account = try AccountDAO.find(db, id: accountID) else { return false }
            return try AccountDAO.setOpeningBalance(db, id: accountID, currency: currency ?? account.currency, amountMinor: amountMinor, at: now)
        }
        if !updated { throw BackendError.notFound }
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
            let allowed: Bool
            if !item.candidateAccountIDs.isEmpty {
                allowed = item.candidateAccountIDs.contains(accountID)
            } else if let tail = draft.cardTail, accounts.contains(where: { !$0.archived && $0.last4 == tail }) {
                allowed = account.last4 == tail
            } else {
                // 通知里没有尾号，或尾号对不上任何卡：由用户选择记入哪张卡
                allowed = !account.archived
            }
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

    /// 每张卡每个币种的余额，币种顺序与账户一致（主币种在前）。
    public func balanceSummaries() async throws -> [String: AccountBalances] {
        try await database.read { db in
            var result: [String: AccountBalances] = [:]
            for account in try AccountDAO.all(db, includeArchived: true) {
                let items = try account.currencies.map { try Self.balanceSummary(db, account: account, currency: $0) }
                result[account.id] = AccountBalances(accountID: account.id, items: items)
            }
            return result
        }
    }

    /// 推算余额：从用户填写的初始余额出发，加上之后到达的已入账流水。没有初始余额时余额未知，不用部分流水冒充。
    /// 银行通知里写的余额不使用：很多银行的通知不带余额，写法和含义也不统一。
    ///
    /// 初始余额是用户在手机上填写的时刻；流水按「通知到达手机的时间」和它比较
    /// （通知内时间是银行所在地的时间，和手机时区可能不同）。
    static func balanceSummary(_ db: SQLiteConnection, account: Account, currency: CurrencyCode) throws -> AccountBalanceSummary {
        guard let opening = account.openingBalance(currency) else {
            return AccountBalanceSummary(accountID: account.id, currency: currency, ledgerDerivedMinor: nil, recordsAfterBase: 0)
        }
        var total = opening.amountMinor
        var count = 0
        for record in try RecordDAO.postedAfter(db, accountID: account.id, currency: currency) {
            guard (record.receivedAt ?? record.processedAt) > opening.at else { continue }
            total += record.direction == .inflow ? record.amountMinor : -record.amountMinor
            count += 1
        }
        return AccountBalanceSummary(
            accountID: account.id, currency: currency, ledgerDerivedMinor: total, recordsAfterBase: count,
            openingBalanceMinor: opening.amountMinor, openingBalanceAt: opening.at
        )
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
