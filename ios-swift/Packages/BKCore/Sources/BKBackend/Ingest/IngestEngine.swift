import Foundation
import BKModel
import BKDatabase

/// 账户匹配：尾号 + 银行 + 快捷指令绑定的账户。冲突时不强行入账。
enum AccountMatcher {
    enum Result: Equatable {
        case matched(Account)
        case ambiguous([Account])
        /// 正文没有尾号，只有绑定账户可作为候选（需要用户确认）
        case boundOnly(Account)
        case none
    }

    static func match(tail: String?, bankHint: String?, boundAccountID: String?, accounts: [Account]) -> Result {
        let active = accounts.filter { !$0.archived }
        let bound = boundAccountID.flatMap { id in active.first { $0.id == id } }
        func bankCompatible(_ account: Account) -> Bool {
            guard let bankHint, let bankID = account.bankID else { return true }
            return bankID == bankHint
        }
        guard let tail else {
            if let bound, bankCompatible(bound) { return .boundOnly(bound) }
            return .none
        }
        let sameTail = active.filter { $0.last4 == tail }
        if let bound, sameTail.contains(bound) { return .matched(bound) }
        let candidates = sameTail.filter(bankCompatible)
        switch candidates.count {
        case 0: return sameTail.isEmpty ? .none : .ambiguous(sameTail)
        case 1: return .matched(candidates[0])
        default: return .ambiguous(candidates)
        }
    }
}

/// 一次入账在数据库事务里的全部步骤。所有函数都在 `Database.write` 的闭包里执行。
struct IngestEngine {
    let db: SQLiteConnection
    let now: Date
    let calendar: Calendar
    let newID: @Sendable () -> String

    struct IngestMeta {
        var ingestID: String
        var source: SourceKind
        var receivedAt: Date?
        var processedAt: Date
    }

    enum CommitOutcome: Equatable {
        case recorded(String)
        case merged(String)
        case pending(PendingReason, candidates: [String], duplicateOf: String?)
    }

    static let retentionKey = "raw_retention_days"
    static let defaultRetentionDays = 30

    func retentionDays() throws -> Int {
        try SettingsDAO.get(db, Self.retentionKey).flatMap(Int.init) ?? Self.defaultRetentionDays
    }

    // MARK: 入口

    func run(_ request: IngestRequest) throws -> IngestResult {
        let normalized = TextNormalizer.normalize(request.text)
        let receivedPart = request.receivedAt.map { String(Int64(($0.timeIntervalSince1970 * 1000).rounded())) } ?? ""
        let fingerprint = SHA256.hex([
            request.source.rawValue,
            request.messageID.map { "id:" + $0 } ?? normalized,
            request.sender ?? "",
            request.subject ?? "",
            receivedPart,
        ].joined(separator: "\u{1F}"))

        if try IngestDAO.exists(db, fingerprint: fingerprint) != nil {
            return IngestResult(ingestID: nil, outcome: .duplicateInput, classification: .transaction, recordedCount: 0, mergedCount: 0, pendingCount: 0, summary: "重复的输入，已忽略")
        }

        let ingestID = newID()
        let parsed = MessageParser.parse(MessageContext(
            text: request.text, source: request.source, sender: request.sender, subject: request.subject,
            referenceDate: request.receivedAt ?? now, calendar: calendar
        ))
        let retention = try retentionDays()
        // 验证码和空输入不保存正文；其余按保留期限保存，便于核对和处理待处理项
        let storeRaw = parsed.classification != .verificationCode && parsed.classification != .empty
        let rawText = storeRaw ? String(request.text.prefix(20_000)) : nil
        let purgeAfter = storeRaw ? now.addingTimeInterval(Double(retention) * 86_400) : nil
        try IngestDAO.insert(
            db, id: ingestID, fingerprint: fingerprint, request: request, processedAt: now, rawText: rawText,
            rawPurgeAfter: purgeAfter, classification: parsed.classification, outcome: .filtered, detail: "", parserVersion: MessageParser.version
        )
        let meta = IngestMeta(ingestID: ingestID, source: request.source, receivedAt: request.receivedAt, processedAt: now)
        let accounts = try AccountDAO.all(db)

        var recorded = 0, merged = 0, pending = 0
        if parsed.classification == .transaction {
            for event in parsed.events {
                let outcome: CommitOutcome
                if let issue = event.issue {
                    let candidates = candidateIDs(for: event.draft, request: request, accounts: accounts)
                    outcome = .pending(issue, candidates: candidates, duplicateOf: nil)
                } else {
                    outcome = try commit(event.draft, meta: meta, boundAccountID: request.boundAccountID, accounts: accounts, forcedAccount: nil, duplicateCheck: true)
                }
                switch outcome {
                case .recorded: recorded += 1
                case .merged: merged += 1
                case let .pending(reason, candidates, duplicateOf):
                    try PendingDAO.insert(db, id: newID(), ingestID: ingestID, partIndex: event.draft.partIndex, reason: reason, draft: event.draft, candidates: candidates, duplicateOf: duplicateOf, now: now)
                    pending += 1
                }
            }
        } else if parsed.classification == .unrecognized {
            try PendingDAO.insert(db, id: newID(), ingestID: ingestID, partIndex: 0, reason: .unrecognized, draft: nil, candidates: request.boundAccountID.map { [$0] } ?? [], duplicateOf: nil, now: now)
            pending += 1
        }

        // 只有余额、没有交易：保存余额快照，不凭差额编造交易
        var balanceSaved = 0
        for balance in parsed.balances {
            guard case let .matched(account) = AccountMatcher.match(tail: balance.cardTail, bankHint: parsed.bankHint, boundAccountID: request.boundAccountID, accounts: accounts),
                  let currency = resolveCurrency(balance.amount, account: account),
                  case let .success(minor) = AmountParser.minorUnits(balance.amount.digits, exponent: currency.minorUnitExponent) else { continue }
            let observation = BalanceObservation(
                accountID: account.id, amountMinor: balance.negative ? -minor : minor, currency: currency,
                orderKey: orderKey(time: balance.transactionTime, fallback: meta.receivedAt ?? now), transactionTime: balance.transactionTime,
                observedAt: meta.receivedAt ?? now, recordID: nil
            )
            try BalanceDAO.insert(db, id: newID(), observation: observation, ingestID: ingestID)
            try AccountDAO.noteSuccess(db, id: account.id, at: now, source: request.source)
            balanceSaved += 1
        }

        let outcome: IngestOutcome
        if pending > 0 { outcome = .pending }
        else if recorded > 0 { outcome = .recorded }
        else if merged > 0 { outcome = .mergedDuplicate }
        else { outcome = .filtered }

        var parts: [String] = []
        if recorded > 0 { parts.append("入账 \(recorded) 笔") }
        if merged > 0 { parts.append("与已有流水合并 \(merged) 笔") }
        if pending > 0 { parts.append("待处理 \(pending) 条") }
        if balanceSaved > 0 { parts.append("更新余额 \(balanceSaved) 个账户") }
        if parts.isEmpty { parts.append(parsed.classification.displayName) }
        let summary = parts.joined(separator: "，")
        // 待处理项的正文要保留到处理完；其余按保留期限清理
        try IngestDAO.updateResult(db, id: ingestID, classification: parsed.classification, outcome: outcome, detail: summary, rawPurgeAfter: purgeAfter)
        return IngestResult(ingestID: ingestID, outcome: outcome, classification: parsed.classification, recordedCount: recorded, mergedCount: merged, pendingCount: pending, summary: summary)
    }

    func candidateIDs(for draft: EventDraft, request: IngestRequest, accounts: [Account]) -> [String] {
        switch AccountMatcher.match(tail: draft.cardTail, bankHint: draft.bankHint, boundAccountID: request.boundAccountID, accounts: accounts) {
        case let .matched(a): [a.id]
        case let .ambiguous(list): list.map(\.id)
        case let .boundOnly(a): [a.id]
        case .none: []
        }
    }

    // MARK: 草稿 → 记录

    /// 通知没写币种、或只写了「元」这类含糊写法时记为账户主币种；
    /// 否则优先取账户持有的币种（多币种账户里「¥」「$」等写法据此区分）。
    func resolveCurrency(_ amount: AmountText, account: Account) -> CurrencyCode? {
        let candidates = amount.currencyCandidates
        if candidates.isEmpty || candidates.contains(account.currency) { return account.currency }
        let held = account.currencies
        if let preferred = amount.preferredCurrency, candidates.contains(preferred), held.contains(preferred) { return preferred }
        if let match = held.first(where: candidates.contains) { return match }
        if candidates.count == 1 { return candidates[0] }
        return amount.preferredCurrency
    }

    /// 把一份完整草稿写成记录；需要用户介入时返回 `.pending`，不写记录。
    func commit(_ draft: EventDraft, meta: IngestMeta, boundAccountID: String?, accounts: [Account], forcedAccount: Account?, duplicateCheck: Bool, forcedDedupeKey: String? = nil) throws -> CommitOutcome {
        let account: Account
        if let forcedAccount {
            account = forcedAccount
        } else {
            switch AccountMatcher.match(tail: draft.cardTail, bankHint: draft.bankHint, boundAccountID: boundAccountID, accounts: accounts) {
            case let .matched(a): account = a
            case let .ambiguous(list): return .pending(.ambiguousAccount, candidates: list.map(\.id), duplicateOf: nil)
            case let .boundOnly(a): return .pending(.missingCardTail, candidates: [a.id], duplicateOf: nil)
            case .none: return .pending(draft.cardTail == nil ? .missingCardTail : .noMatchingAccount, candidates: [], duplicateOf: nil)
            }
        }

        guard let currency = resolveCurrency(draft.amount, account: account) else {
            return .pending(.unknownCurrency, candidates: [account.id], duplicateOf: nil)
        }
        let exponent = currency.minorUnitExponent
        guard case var .success(amountMinor) = AmountParser.minorUnits(draft.amount.digits, exponent: exponent) else {
            return .pending(.ambiguousAmount, candidates: [account.id], duplicateOf: nil)
        }
        var includedFeeMinor: Int64?
        if let fee = draft.includedFee {
            guard case let .success(feeMinor) = AmountParser.minorUnits(fee.digits, exponent: exponent), feeMinor < amountMinor else {
                return .pending(.ambiguousAmount, candidates: [account.id], duplicateOf: nil)
            }
            includedFeeMinor = feeMinor
            amountMinor -= feeMinor
        }
        var balanceMinor: Int64?
        if let balance = draft.balanceAfter, resolveCurrency(balance, account: account) == currency,
           case let .success(value) = AmountParser.minorUnits(balance.digits, exponent: exponent) {
            balanceMinor = value
        }
        let direction: FlowDirection
        if let explicit = draft.direction {
            direction = explicit
        } else if draft.kind == .repayment {
            direction = account.cardType == .credit ? .inflow : .outflow
        } else {
            return .pending(.uncertainKind, candidates: [account.id], duplicateOf: nil)
        }

        let record = LedgerRecord(
            id: newID(), accountID: account.id, amountMinor: amountMinor, currency: currency, direction: direction,
            kind: draft.kind, status: draft.status, counterparty: draft.counterparty, transactionTime: draft.transactionTime,
            receivedAt: meta.receivedAt, processedAt: meta.processedAt, source: meta.source, ingestID: meta.ingestID,
            partIndex: draft.partIndex, bankReference: draft.bankReference, balanceAfterMinor: balanceMinor,
            includedFeeMinor: includedFeeMinor, note: "", transferGroupID: nil, relatedRecordID: nil
        )

        let key = forcedDedupeKey ?? dedupeKey(record)
        if let existingID = try RecordDAO.idForDedupeKey(db, key), let existing = try RecordDAO.find(db, id: existingID) {
            // 同一笔交易的另一来源（短信 + 邮件），证据充分：合并为来源证据
            if existing.source != meta.source || !duplicateCheck {
                try RecordDAO.addEvidence(db, recordID: existingID, ingestID: meta.ingestID, source: meta.source, at: now)
                try AccountDAO.noteSuccess(db, id: account.id, at: now, source: meta.source)
                return .merged(existingID)
            }
            // 同一来源、内容不同但特征一致：可能是两笔真实交易，交给用户判断
            return .pending(.possibleDuplicate, candidates: [account.id], duplicateOf: existingID)
        }
        if duplicateCheck, let similar = try possibleDuplicate(of: record) {
            return .pending(.possibleDuplicate, candidates: [account.id], duplicateOf: similar.id)
        }
        guard try RecordDAO.insertIfAbsent(db, record, dedupeKey: key, now: now) else {
            // 事务内不会发生；保守处理为合并
            let existingID = try RecordDAO.idForDedupeKey(db, key) ?? record.id
            try RecordDAO.addEvidence(db, recordID: existingID, ingestID: meta.ingestID, source: meta.source, at: now)
            return .merged(existingID)
        }
        try RecordDAO.addEvidence(db, recordID: record.id, ingestID: meta.ingestID, source: meta.source, at: now)
        if let balanceMinor {
            let observation = BalanceObservation(
                accountID: account.id, amountMinor: balanceMinor, currency: currency,
                orderKey: orderKey(time: record.transactionTime, fallback: record.effectiveAt), transactionTime: record.transactionTime,
                observedAt: record.effectiveAt, recordID: record.id
            )
            try BalanceDAO.insert(db, id: newID(), observation: observation, ingestID: meta.ingestID)
        }
        try AccountDAO.noteSuccess(db, id: account.id, at: now, source: meta.source)
        try linkTransfer(record, counterpartyTail: draft.counterpartyTail, accounts: accounts)
        try linkRefund(record)
        return .recorded(record.id)
    }

    /// 去重键：可信交易标识 > 精确到分钟的交易时间 + 金额特征 > 本次输入内唯一。
    func dedupeKey(_ r: LedgerRecord) -> String {
        let role = r.partIndex % 2 == 1 ? "fee" : "main"
        if let reference = r.bankReference {
            return ["ref", r.accountID, reference, role].joined(separator: "|")
        }
        if let time = r.transactionTime, time.isMinutePrecise {
            return ["t", r.accountID, r.direction.rawValue, String(r.amountMinor), r.currency.rawValue, r.kind.rawValue, r.status.rawValue, time.sortKey, r.balanceAfterMinor.map(String.init) ?? "-", role].joined(separator: "|")
        }
        return ["i", r.ingestID, String(r.partIndex)].joined(separator: "|")
    }

    /// 跨来源的近似重复：同账户、同金额币种方向，来源不同、系统时间 20 分钟内，且正文时间不冲突。
    func possibleDuplicate(of record: LedgerRecord) throws -> LedgerRecord? {
        let window: TimeInterval = 20 * 60
        let candidates = try RecordDAO.candidates(
            db, amountMinor: record.amountMinor, currency: record.currency, direction: record.direction,
            effectiveFrom: record.effectiveAt.addingTimeInterval(-window), effectiveTo: record.effectiveAt.addingTimeInterval(window),
            excludingIngest: record.ingestID
        )
        return candidates.first { other in
            guard other.accountID == record.accountID, other.status == record.status, other.source != record.source else { return false }
            if let a = other.transactionTime, let b = record.transactionTime, a.isMinutePrecise, b.isMinutePrecise, a.sortKey != b.sortKey { return false }
            if let a = other.balanceAfterMinor, let b = record.balanceAfterMinor, a != b { return false }
            return true
        }
    }

    /// 自己两张卡之间的转账：两边流水都保留，可靠关联时标记同一转账组。
    func linkTransfer(_ record: LedgerRecord, counterpartyTail: String?, accounts: [Account]) throws {
        guard record.status == .posted, record.kind.isTransferLike else { return }
        let peerAccounts = counterpartyTail.map { tail in accounts.filter { $0.last4 == tail && $0.id != record.accountID && !$0.archived } } ?? []
        let window: TimeInterval = 30 * 60
        var candidates = try RecordDAO.candidates(
            db, amountMinor: record.amountMinor, currency: record.currency, direction: record.direction.opposite,
            effectiveFrom: record.effectiveAt.addingTimeInterval(-window), effectiveTo: record.effectiveAt.addingTimeInterval(window),
            excludingIngest: record.ingestID
        ).filter { $0.accountID != record.accountID && $0.status == .posted && $0.kind.isTransferLike }
        candidates = try candidates.filter { candidate in
            guard let group = candidate.transferGroupID else { return true }
            return try RecordDAO.inGroup(db, group: group).count == 1
        }
        if !peerAccounts.isEmpty {
            let preferred = candidates.filter { c in peerAccounts.contains { $0.id == c.accountID } }
            if !preferred.isEmpty { candidates = preferred }
        }
        if candidates.count == 1 {
            let peer = candidates[0]
            let group = peer.transferGroupID ?? newID()
            try RecordDAO.setTransferGroup(db, ids: [record.id, peer.id], group: group)
        } else if candidates.isEmpty, peerAccounts.count == 1 {
            // 正文明确写了对方是自己的另一张卡，但对方的通知还没到：先单边标记为内部转账
            try RecordDAO.setTransferGroup(db, ids: [record.id], group: newID())
        }
    }

    /// 退款 / 冲正：能唯一找到原交易时建立关联，原交易保持不变。
    func linkRefund(_ record: LedgerRecord) throws {
        guard record.direction == .inflow, record.kind == .refund || record.kind == .reversal, let counterparty = record.counterparty else { return }
        let origins = try RecordDAO.refundOriginCandidates(
            db, accountID: record.accountID, counterparty: counterparty, minAmount: record.amountMinor, currency: record.currency,
            before: record.effectiveAt, after: record.effectiveAt.addingTimeInterval(-180 * 86_400)
        ).filter { $0.id != record.id }
        if origins.count == 1 { try RecordDAO.setRelated(db, id: record.id, relatedID: origins[0].id) }
    }

    func orderKey(time: WallClock?, fallback: Date) -> String {
        if let time, time.year != nil, time.hasDate { return time.sortKey }
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: fallback)
        return WallClock(year: c.year, month: c.month, day: c.day, hour: c.hour, minute: c.minute, second: c.second).sortKey
    }
}
