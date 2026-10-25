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
        let accounts = try AccountDAO.all(db)
        // 固定写法认不出尾号时，在正文里找已添加的卡的尾号
        let fallbackTail = Self.knownTail(in: parsed.cleanedText, accounts: accounts)

        // 自动化可以对所有短信 / 邮件触发。没有任何尾号、看不出是哪家银行、也没有绑定账户的，不当作动账通知
        // （例如朋友发来「转我100元」），不进待处理
        var classification = parsed.classification
        if [MessageClassification.transaction, .unrecognized, .marketing].contains(classification),
           parsed.cardTails.isEmpty, fallbackTail == nil, parsed.bankHint == nil, request.boundAccountID == nil {
            classification = .noFinancialContent
        }
        // 不是动账通知的不保存，也不写接收日志：普通短信、邮件不会留在 App 里
        if classification == .noFinancialContent {
            return IngestResult(ingestID: nil, outcome: .filtered, classification: classification, recordedCount: 0, mergedCount: 0, pendingCount: 0, summary: classification.displayName)
        }

        let retention = try retentionDays()
        // 验证码和空输入不保存正文；其余按保留期限保存，便于核对和处理待处理项
        let storeRaw = classification != .verificationCode && classification != .empty
        let rawText = storeRaw ? String(request.text.prefix(20_000)) : nil
        let purgeAfter = storeRaw ? now.addingTimeInterval(Double(retention) * 86_400) : nil
        try IngestDAO.insert(
            db, id: ingestID, fingerprint: fingerprint, request: request, processedAt: now, rawText: rawText,
            rawPurgeAfter: purgeAfter, classification: classification, outcome: .filtered, detail: "", parserVersion: MessageParser.version
        )
        let meta = IngestMeta(ingestID: ingestID, source: request.source, receivedAt: request.receivedAt, processedAt: now)

        var recorded = 0, merged = 0, pending = 0
        var items: [IngestItem] = []
        if classification == .transaction {
            for event in parsed.events {
                var draft = event.draft
                if draft.cardTail == nil { draft.cardTail = fallbackTail }
                let outcome: CommitOutcome
                if let issue = event.issue {
                    let candidates = candidateIDs(for: draft, request: request, accounts: accounts)
                    outcome = .pending(issue, candidates: candidates, duplicateOf: nil)
                } else {
                    outcome = try commit(draft, meta: meta, boundAccountID: request.boundAccountID, accounts: accounts, forcedAccount: nil, duplicateCheck: true)
                }
                switch outcome {
                case let .recorded(recordID):
                    recorded += 1
                    items.append(try item(recordID: recordID, draft: draft, result: .recorded, accounts: accounts))
                case let .merged(recordID):
                    merged += 1
                    items.append(try item(recordID: recordID, draft: draft, result: .merged, accounts: accounts))
                case let .pending(reason, candidates, duplicateOf):
                    try PendingDAO.insert(db, id: newID(), ingestID: ingestID, partIndex: draft.partIndex, reason: reason, draft: draft, candidates: candidates, duplicateOf: duplicateOf, now: now)
                    pending += 1
                    items.append(Self.pendingItem(draft, reason: reason))
                }
            }
        } else if classification == .unrecognized {
            try PendingDAO.insert(db, id: newID(), ingestID: ingestID, partIndex: 0, reason: .unrecognized, draft: nil, candidates: request.boundAccountID.map { [$0] } ?? [], duplicateOf: nil, now: now)
            pending += 1
            items.append(IngestItem(cardTail: nil, kind: nil, status: nil, amountMinor: nil, currency: nil, amountText: nil, result: .pending(.unrecognized)))
        }

        // 只有余额、没有交易：不入账，也不保存余额（卡片余额只从初始余额推算）；能对上卡时记为这张卡收到过自动输入
        for balance in parsed.balances {
            guard case let .matched(account) = AccountMatcher.match(tail: balance.cardTail, bankHint: parsed.bankHint, boundAccountID: request.boundAccountID, accounts: accounts) else { continue }
            try AccountDAO.noteSuccess(db, id: account.id, at: now, source: request.source)
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
        if parts.isEmpty { parts.append(classification.displayName) }
        let summary = parts.joined(separator: "，")
        // 待处理项的正文要保留到处理完；其余按保留期限清理
        try IngestDAO.updateResult(db, id: ingestID, classification: classification, outcome: outcome, detail: summary, rawPurgeAfter: purgeAfter)
        return IngestResult(ingestID: ingestID, outcome: outcome, classification: classification, recordedCount: recorded, mergedCount: merged, pendingCount: pending, summary: summary, items: items)
    }

    /// 已入账 / 已合并的一笔：用流水本身的金额、币种和账户尾号
    private func item(recordID: String, draft: EventDraft, result: IngestItem.Result, accounts: [Account]) throws -> IngestItem {
        guard let record = try RecordDAO.find(db, id: recordID) else {
            return Self.pendingItem(draft, result: result)
        }
        let tail = accounts.first { $0.id == record.accountID }?.last4 ?? draft.cardTail
        return IngestItem(cardTail: tail, kind: record.kind, status: record.status, amountMinor: record.amountMinor, currency: record.currency, amountText: nil, result: result)
    }

    /// 没有入账的一笔：只有通知里写的尾号和金额原文
    static func pendingItem(_ draft: EventDraft, reason: PendingReason) -> IngestItem {
        pendingItem(draft, result: .pending(reason))
    }

    private static func pendingItem(_ draft: EventDraft, result: IngestItem.Result) -> IngestItem {
        let candidates = draft.amount.currencyCandidates
        let currency = draft.amount.preferredCurrency ?? (candidates.count == 1 ? candidates[0] : nil)
        return IngestItem(cardTail: draft.cardTail, kind: draft.kind, status: draft.status, amountMinor: nil, currency: currency, amountText: draft.amount.digits, result: result)
    }

    /// 正文里没认出尾号时，找已添加的卡的尾号：作为单独的 4 位数字出现、并且只有一张卡的尾号出现时，就是这张卡。
    /// 各家银行、各种语言写尾号的方式不同（「結尾號碼8482」「a/c XX8482」），这样不依赖固定写法。
    /// 排除明显不是尾号的位置：更长数字的一部分、日期（2026年、23/10/2026）、金额（CNY8482、8482元、8482.00）。
    static func knownTail(in text: String, accounts: [Account]) -> String? {
        let tails = Set(accounts.filter { !$0.archived }.map(\.last4)).filter { $0.count == 4 && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }
        var found = tails.filter { tail in
            text.range(of: "(?<![0-9/.:$¥€£A-WYZa-wyz-])\(tail)(?![0-9年月日元圆号]|[.,][0-9])", options: .regularExpression) != nil
        }
        // 出现多个时，像年份的（「24 Oct 2026」）不算
        if found.count > 1 { found = found.filter { !(1990...2099).contains(Int($0) ?? 0) } }
        return found.count == 1 ? found.first : nil
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
            // 同一笔交易的另一来源（短信 + 邮件 + App 通知），证据充分：合并为来源证据。
            // 来源分不出（一个自动化接收全部）时，同一来源的同一条输入已由指纹去重，这里视为另一来源
            if existing.source != meta.source || meta.source == .auto || !duplicateCheck {
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

    /// 跨来源的近似重复：同账户、同金额币种方向，来源不同（或分不出来源）、系统时间 20 分钟内，且正文时间不冲突。
    func possibleDuplicate(of record: LedgerRecord) throws -> LedgerRecord? {
        let window: TimeInterval = 20 * 60
        let candidates = try RecordDAO.candidates(
            db, amountMinor: record.amountMinor, currency: record.currency, direction: record.direction,
            effectiveFrom: record.effectiveAt.addingTimeInterval(-window), effectiveTo: record.effectiveAt.addingTimeInterval(window),
            excludingIngest: record.ingestID
        )
        return candidates.first { other in
            guard other.accountID == record.accountID, other.status == record.status,
                  other.source != record.source || record.source == .auto else { return false }
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
