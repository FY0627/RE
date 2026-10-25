import Foundation
import BKModel

/// 数据访问函数。全部接收 `SQLiteConnection`，只能在 `Database.read/write` 的闭包里调用。
public enum AccountDAO {
    static let columns = "id, name, bank_id, bank_name, last4, card_type, currency, palette_id, sort_order, created_at, archived, opening_balance_minor, opening_balance_at, card_number, face_image_id, face_text_color, face_text_scale"

    static func map(_ row: SQLiteConnection.Row) -> Account {
        Account(
            id: row.string(0), name: row.string(1), bankID: row.optionalString(2), bankName: row.string(3),
            last4: row.string(4), cardType: CardType(rawValue: row.string(5)) ?? .other,
            currency: CurrencyCode(row.string(6)), paletteID: row.string(7), sortOrder: Int(row.int(8)),
            createdAt: row.date(9), archived: row.bool(10),
            openingBalanceMinor: row.optionalInt(11), openingBalanceAt: row.optionalDate(12),
            cardNumber: row.optionalString(13),
            face: CardFace(imageID: row.optionalString(14), textColor: row.optionalInt(15).map { UInt32(truncatingIfNeeded: $0) }, textScale: row.double(16))
        )
    }

    public static func all(_ db: SQLiteConnection, includeArchived: Bool = false) throws -> [Account] {
        let filter = includeArchived ? "" : "WHERE archived = 0"
        return try db.query("SELECT \(columns) FROM accounts \(filter) ORDER BY sort_order, created_at", [], map)
    }

    public static func find(_ db: SQLiteConnection, id: String) throws -> Account? {
        try db.queryOne("SELECT \(columns) FROM accounts WHERE id = ?", [id], map)
    }

    public static func insert(_ db: SQLiteConnection, _ a: Account) throws {
        try db.run(
            "INSERT INTO accounts (\(columns)) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            [a.id, a.name, a.bankID, a.bankName, a.last4, a.cardType.rawValue, a.currency.rawValue, a.paletteID, a.sortOrder, a.createdAt, a.archived,
             a.openingBalanceMinor, a.openingBalanceAt, a.cardNumber, a.face.imageID, a.face.textColor.map { Int64($0) }, a.face.textScale]
        )
    }

    public static func nextSortOrder(_ db: SQLiteConnection) throws -> Int {
        Int(try db.scalarInt("SELECT COALESCE(MAX(sort_order), -1) + 1 FROM accounts"))
    }

    @discardableResult
    public static func updateFace(_ db: SQLiteConnection, id: String, paletteID: String, face: CardFace) throws -> Bool {
        try db.run(
            "UPDATE accounts SET palette_id = ?, face_image_id = ?, face_text_color = ?, face_text_scale = ? WHERE id = ?",
            [paletteID, face.imageID, face.textColor.map { Int64($0) }, face.textScale, id]
        ) > 0
    }

    @discardableResult
    public static func updateInfo(_ db: SQLiteConnection, id: String, name: String, cardNumber: String?) throws -> Bool {
        try db.run("UPDATE accounts SET name = ?, card_number = ? WHERE id = ?", [name, cardNumber, id]) > 0
    }

    public static func setArchived(_ db: SQLiteConnection, id: String, archived: Bool) throws {
        try db.run("UPDATE accounts SET archived = ? WHERE id = ?", [archived, id])
    }

    /// 设置或清除初始余额。清除时两个字段一起置空。
    @discardableResult
    public static func setOpeningBalance(_ db: SQLiteConnection, id: String, amountMinor: Int64?, at date: Date?) throws -> Bool {
        try db.run(
            "UPDATE accounts SET opening_balance_minor = ?, opening_balance_at = ? WHERE id = ?",
            [amountMinor, amountMinor == nil ? nil : date, id]
        ) > 0
    }

    public static func noteSuccess(_ db: SQLiteConnection, id: String, at date: Date, source: SourceKind) throws {
        try db.run(
            "UPDATE accounts SET last_success_at = MAX(COALESCE(last_success_at, 0), ?), last_success_source = ?, received_count = received_count + 1 WHERE id = ?",
            [date, source.rawValue, id]
        )
    }

    public static func automationStatus(_ db: SQLiteConnection) throws -> [AccountAutomationStatus] {
        try db.query("SELECT id, last_success_at, last_success_source, received_count FROM accounts", []) { row in
            AccountAutomationStatus(
                accountID: row.string(0), lastSuccessAt: row.optionalDate(1),
                lastSuccessSource: row.optionalString(2).flatMap(SourceKind.init(rawValue:)), receivedCount: Int(row.int(3))
            )
        }
    }
}

public enum RecordDAO {
    static let columns = """
    r.id, r.account_id, r.amount_minor, r.currency, r.direction, r.kind, r.status, r.counterparty, r.txn_time, r.txn_year_inferred, \
    r.received_at, r.processed_at, r.source, r.ingest_id, r.part_index, r.bank_reference, r.balance_after_minor, r.included_fee_minor, \
    r.note, r.transfer_group, r.related_record_id
    """
    static let rowColumns = columns + ", a.name, a.bank_name, a.last4, a.palette_id"

    static func map(_ row: SQLiteConnection.Row) -> LedgerRecord {
        LedgerRecord(
            id: row.string(0), accountID: row.string(1), amountMinor: row.int(2), currency: CurrencyCode(row.string(3)),
            direction: FlowDirection(rawValue: row.string(4)) ?? .outflow, kind: TransactionKind(rawValue: row.string(5)) ?? .other,
            status: SettlementStatus(rawValue: row.string(6)) ?? .posted, counterparty: row.optionalString(7),
            transactionTime: row.optionalString(8).flatMap { WallClockCodec.decode($0, yearInferred: row.bool(9)) },
            receivedAt: row.optionalDate(10), processedAt: row.date(11), source: SourceKind(rawValue: row.string(12)) ?? .other,
            ingestID: row.string(13), partIndex: Int(row.int(14)), bankReference: row.optionalString(15),
            balanceAfterMinor: row.optionalInt(16), includedFeeMinor: row.optionalInt(17), note: row.string(18),
            transferGroupID: row.optionalString(19), relatedRecordID: row.optionalString(20)
        )
    }

    static func mapRow(_ row: SQLiteConnection.Row) -> RecordRow {
        RecordRow(record: map(row), accountName: row.string(21), bankName: row.string(22), last4: row.string(23), paletteID: row.string(24))
    }

    /// 插入一条记录。`dedupe_key` 冲突时返回 false（说明是重复），不抛错。
    public static func insertIfAbsent(_ db: SQLiteConnection, _ r: LedgerRecord, dedupeKey: String, now: Date) throws -> Bool {
        let changed = try db.run(
            """
            INSERT OR IGNORE INTO records (id, account_id, amount_minor, currency, direction, kind, status, counterparty, txn_time, \
            txn_year_inferred, received_at, processed_at, effective_at, source, ingest_id, part_index, bank_reference, balance_after_minor, \
            included_fee_minor, note, transfer_group, related_record_id, dedupe_key, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                r.id, r.accountID, r.amountMinor, r.currency.rawValue, r.direction.rawValue, r.kind.rawValue, r.status.rawValue,
                r.counterparty, r.transactionTime.map(WallClockCodec.encode), r.transactionTime?.yearInferred ?? false,
                r.receivedAt, r.processedAt, r.effectiveAt, r.source.rawValue, r.ingestID, r.partIndex, r.bankReference,
                r.balanceAfterMinor, r.includedFeeMinor, r.note, r.transferGroupID, r.relatedRecordID, dedupeKey, now,
            ]
        )
        return changed > 0
    }

    public static func idForDedupeKey(_ db: SQLiteConnection, _ key: String) throws -> String? {
        try db.queryOne("SELECT id FROM records WHERE dedupe_key = ?", [key]) { $0.string(0) }
    }

    public static func find(_ db: SQLiteConnection, id: String) throws -> LedgerRecord? {
        try db.queryOne("SELECT \(columns) FROM records r WHERE r.id = ?", [id], map)
    }

    public static func findRow(_ db: SQLiteConnection, id: String) throws -> RecordRow? {
        try db.queryOne("SELECT \(rowColumns) FROM records r JOIN accounts a ON a.id = r.account_id WHERE r.id = ?", [id], mapRow)
    }

    /// 首页：全部账户流水，按系统时间倒序，键集分页。
    public static func page(_ db: SQLiteConnection, accountID: String?, before cursor: RecordCursor?, limit: Int) throws -> [RecordRow] {
        var conditions: [String] = []
        var values: [SQLBindable] = []
        if let accountID {
            conditions.append("r.account_id = ?")
            values.append(accountID)
        }
        if let cursor {
            conditions.append("(r.effective_at < ? OR (r.effective_at = ? AND r.id < ?))")
            values.append(cursor.effectiveAt)
            values.append(cursor.effectiveAt)
            values.append(cursor.id)
        }
        let whereClause = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
        values.append(limit)
        return try db.query(
            "SELECT \(rowColumns) FROM records r JOIN accounts a ON a.id = r.account_id \(whereClause) ORDER BY r.effective_at DESC, r.id DESC LIMIT ?",
            values, mapRow
        )
    }

    public static func count(_ db: SQLiteConnection, accountID: String? = nil) throws -> Int {
        if let accountID {
            return Int(try db.scalarInt("SELECT COUNT(*) FROM records WHERE account_id = ?", [accountID]))
        }
        return Int(try db.scalarInt("SELECT COUNT(*) FROM records"))
    }

    public static func updateNote(_ db: SQLiteConnection, id: String, note: String) throws -> Bool {
        try db.run("UPDATE records SET note = ? WHERE id = ?", [note, id]) > 0
    }

    public static func setTransferGroup(_ db: SQLiteConnection, ids: [String], group: String) throws {
        for id in ids { try db.run("UPDATE records SET transfer_group = ? WHERE id = ?", [group, id]) }
    }

    public static func setRelated(_ db: SQLiteConnection, id: String, relatedID: String) throws {
        try db.run("UPDATE records SET related_record_id = ? WHERE id = ?", [relatedID, id])
    }

    /// 金额、币种、方向一致的候选记录（用于跨来源重复检测和内部转账配对）。
    public static func candidates(
        _ db: SQLiteConnection, amountMinor: Int64, currency: CurrencyCode, direction: FlowDirection,
        effectiveFrom: Date, effectiveTo: Date, excludingIngest: String
    ) throws -> [LedgerRecord] {
        try db.query(
            """
            SELECT \(columns) FROM records r
            WHERE r.amount_minor = ? AND r.currency = ? AND r.direction = ? AND r.effective_at BETWEEN ? AND ? AND r.ingest_id <> ?
            ORDER BY r.effective_at
            """,
            [amountMinor, currency.rawValue, direction.rawValue, effectiveFrom, effectiveTo, excludingIngest], map
        )
    }

    public static func inGroup(_ db: SQLiteConnection, group: String) throws -> [LedgerRecord] {
        try db.query("SELECT \(columns) FROM records r WHERE r.transfer_group = ?", [group], map)
    }

    /// 退款关联：同账户、同交易对方、金额不小于退款的较早流出记录。
    public static func refundOriginCandidates(_ db: SQLiteConnection, accountID: String, counterparty: String, minAmount: Int64, currency: CurrencyCode, before: Date, after: Date) throws -> [LedgerRecord] {
        try db.query(
            """
            SELECT \(columns) FROM records r
            WHERE r.account_id = ? AND r.counterparty = ? AND r.direction = 'outflow' AND r.status = 'posted'
              AND r.currency = ? AND r.amount_minor >= ? AND r.effective_at BETWEEN ? AND ?
            """,
            [accountID, counterparty, currency.rawValue, minAmount, after, before], map
        )
    }

    public static func postedAfter(_ db: SQLiteConnection, accountID: String, currency: CurrencyCode) throws -> [LedgerRecord] {
        try db.query(
            "SELECT \(columns) FROM records r WHERE r.account_id = ? AND r.currency = ? AND r.status = 'posted' ORDER BY r.effective_at",
            [accountID, currency.rawValue], map
        )
    }

    public static func addEvidence(_ db: SQLiteConnection, recordID: String, ingestID: String, source: SourceKind, at date: Date) throws {
        try db.run(
            "INSERT OR IGNORE INTO record_evidence (record_id, ingest_id, source, added_at) VALUES (?, ?, ?, ?)",
            [recordID, ingestID, source.rawValue, date]
        )
    }

    public static func evidence(_ db: SQLiteConnection, recordID: String) throws -> [RecordEvidence] {
        try db.query(
            """
            SELECT i.id, i.source, i.sender, i.received_at, i.processed_at, i.raw_text
            FROM record_evidence e JOIN ingests i ON i.id = e.ingest_id WHERE e.record_id = ? ORDER BY i.processed_at
            """,
            [recordID]
        ) { row in
            RecordEvidence(ingestID: row.string(0), source: SourceKind(rawValue: row.string(1)) ?? .other, sender: row.optionalString(2), receivedAt: row.optionalDate(3), processedAt: row.date(4), rawText: row.optionalString(5))
        }
    }

    /// 统计用：时间段内全部记录（只取聚合需要的列由调用方处理）。
    public static func inRange(_ db: SQLiteConnection, from: Date, to: Date) throws -> [LedgerRecord] {
        try db.query("SELECT \(columns) FROM records r WHERE r.effective_at >= ? AND r.effective_at < ?", [from, to], map)
    }
}

public enum IngestDAO {
    public static func exists(_ db: SQLiteConnection, fingerprint: String) throws -> String? {
        try db.queryOne("SELECT id FROM ingests WHERE fingerprint = ?", [fingerprint]) { $0.string(0) }
    }

    public static func insert(
        _ db: SQLiteConnection, id: String, fingerprint: String, request: IngestRequest, processedAt: Date,
        rawText: String?, rawPurgeAfter: Date?, classification: MessageClassification, outcome: IngestOutcome,
        detail: String, parserVersion: Int
    ) throws {
        try db.run(
            """
            INSERT INTO ingests (id, fingerprint, source, sender, subject, received_at, message_id, bound_account_id, processed_at, raw_text, \
            raw_purge_after, classification, outcome, detail, parser_version) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                id, fingerprint, request.source.rawValue, request.sender, request.subject, request.receivedAt, request.messageID,
                request.boundAccountID, processedAt, rawText, rawPurgeAfter, classification.rawValue, outcome.rawValue, detail, parserVersion,
            ]
        )
    }

    public static func updateResult(_ db: SQLiteConnection, id: String, classification: MessageClassification, outcome: IngestOutcome, detail: String, rawPurgeAfter: Date?) throws {
        try db.run(
            "UPDATE ingests SET classification = ?, outcome = ?, detail = ?, raw_purge_after = ? WHERE id = ?",
            [classification.rawValue, outcome.rawValue, detail, rawPurgeAfter, id]
        )
    }

    public static func recent(_ db: SQLiteConnection, limit: Int) throws -> [IngestLogEntry] {
        try db.query(
            "SELECT id, source, sender, subject, received_at, processed_at, classification, outcome, detail, raw_text, bound_account_id FROM ingests ORDER BY processed_at DESC LIMIT ?",
            [limit]
        ) { row in
            IngestLogEntry(
                id: row.string(0), source: SourceKind(rawValue: row.string(1)) ?? .other, sender: row.optionalString(2), subject: row.optionalString(3),
                receivedAt: row.optionalDate(4), processedAt: row.date(5), classification: MessageClassification(rawValue: row.string(6)) ?? .unrecognized,
                outcome: IngestOutcome(rawValue: row.string(7)) ?? .filtered, detail: row.string(8), rawText: row.optionalString(9), boundAccountID: row.optionalString(10)
            )
        }
    }

    public static func meta(_ db: SQLiteConnection, id: String) throws -> (source: SourceKind, sender: String?, receivedAt: Date?, processedAt: Date, rawText: String?)? {
        try db.queryOne("SELECT source, sender, received_at, processed_at, raw_text FROM ingests WHERE id = ?", [id]) { row in
            (SourceKind(rawValue: row.string(0)) ?? .other, row.optionalString(1), row.optionalDate(2), row.date(3), row.optionalString(4))
        }
    }

    /// 清理到期的原始内容：只清空正文，保留指纹（用于幂等去重）和处理结果。
    @discardableResult
    public static func purgeRaw(_ db: SQLiteConnection, now: Date) throws -> Int {
        try db.run(
            """
            UPDATE ingests SET raw_text = NULL WHERE raw_text IS NOT NULL AND raw_purge_after IS NOT NULL AND raw_purge_after <= ?
              AND id NOT IN (SELECT ingest_id FROM pending_items WHERE status = 'open')
            """,
            [now]
        )
    }
}

public enum PendingDAO {
    static let select = """
    SELECT p.id, p.ingest_id, p.reason, p.draft_json, p.candidate_account_ids, p.duplicate_of_record_id, p.status, p.created_at, \
    i.source, i.sender, i.received_at, i.raw_text, p.part_index
    FROM pending_items p JOIN ingests i ON i.id = p.ingest_id
    """

    static func map(_ row: SQLiteConnection.Row) -> PendingItem {
        let draft = row.optionalString(3).flatMap { try? JSONDecoder().decode(EventDraft.self, from: Data($0.utf8)) }
        let candidates = row.string(4).split(separator: ",").map(String.init)
        return PendingItem(
            id: row.string(0), ingestID: row.string(1), reason: PendingReason(rawValue: row.string(2)) ?? .unrecognized, draft: draft,
            candidateAccountIDs: candidates, duplicateOfRecordID: row.optionalString(5), status: PendingStatus(rawValue: row.string(6)) ?? .open,
            createdAt: row.date(7), source: SourceKind(rawValue: row.string(8)) ?? .other, sender: row.optionalString(9),
            receivedAt: row.optionalDate(10), rawText: row.optionalString(11)
        )
    }

    public static func insert(_ db: SQLiteConnection, id: String, ingestID: String, partIndex: Int, reason: PendingReason, draft: EventDraft?, candidates: [String], duplicateOf: String?, now: Date) throws {
        let json = try draft.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
        try db.run(
            "INSERT INTO pending_items (id, ingest_id, part_index, reason, draft_json, candidate_account_ids, duplicate_of_record_id, status, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, 'open', ?)",
            [id, ingestID, partIndex, reason.rawValue, json, candidates.joined(separator: ","), duplicateOf, now]
        )
    }

    public static func open(_ db: SQLiteConnection) throws -> [PendingItem] {
        try db.query(select + " WHERE p.status = 'open' ORDER BY p.created_at DESC", [], map)
    }

    public static func find(_ db: SQLiteConnection, id: String) throws -> PendingItem? {
        try db.queryOne(select + " WHERE p.id = ?", [id], map)
    }

    public static func partIndex(_ db: SQLiteConnection, id: String) throws -> Int {
        Int(try db.scalarInt("SELECT part_index FROM pending_items WHERE id = ?", [id]))
    }

    public static func openCount(_ db: SQLiteConnection) throws -> Int {
        Int(try db.scalarInt("SELECT COUNT(*) FROM pending_items WHERE status = 'open'"))
    }

    public static func resolve(_ db: SQLiteConnection, id: String, status: PendingStatus, at date: Date) throws -> Bool {
        try db.run("UPDATE pending_items SET status = ?, resolved_at = ? WHERE id = ? AND status = 'open'", [status.rawValue, date, id]) > 0
    }
}

public enum BalanceDAO {
    public static func insert(_ db: SQLiteConnection, id: String, observation o: BalanceObservation, ingestID: String) throws {
        try db.run(
            "INSERT INTO balance_observations (id, account_id, amount_minor, currency, order_key, txn_time, observed_at, ingest_id, record_id) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
            [id, o.accountID, o.amountMinor, o.currency.rawValue, o.orderKey, o.transactionTime.map(WallClockCodec.encode), o.observedAt, ingestID, o.recordID]
        )
    }

    /// 最新的银行余额：按通知内时间（order_key）排序，而不是按到达顺序，避免旧消息覆盖新余额。
    public static func latest(_ db: SQLiteConnection, accountID: String) throws -> BalanceObservation? {
        try db.queryOne(
            "SELECT account_id, amount_minor, currency, order_key, txn_time, observed_at, record_id FROM balance_observations WHERE account_id = ? ORDER BY order_key DESC, observed_at DESC LIMIT 1",
            [accountID]
        ) { row in
            BalanceObservation(
                accountID: row.string(0), amountMinor: row.int(1), currency: CurrencyCode(row.string(2)), orderKey: row.string(3),
                transactionTime: row.optionalString(4).flatMap { WallClockCodec.decode($0, yearInferred: false) }, observedAt: row.date(5), recordID: row.optionalString(6)
            )
        }
    }
}

public enum SettingsDAO {
    public static func get(_ db: SQLiteConnection, _ key: String) throws -> String? {
        try db.queryOne("SELECT value FROM settings WHERE key = ?", [key]) { $0.string(0) }
    }

    public static func set(_ db: SQLiteConnection, _ key: String, _ value: String) throws {
        try db.run("INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", [key, value])
    }
}

/// WallClock 与数据库文本的互转：`YYYY-MM-DDTHH:MM[:SS]`，缺失部分用 `?` 占位。
public enum WallClockCodec {
    public static func encode(_ w: WallClock) -> String { w.sortKey }

    public static func decode(_ text: String, yearInferred: Bool) -> WallClock? {
        let parts = text.split(separator: "T", maxSplits: 1).map(String.init)
        guard let datePart = parts.first else { return nil }
        let dateFields = datePart.split(separator: "-").map(String.init)
        let year = dateFields.first.flatMap { Int($0) }
        let month = dateFields.count > 1 ? Int(dateFields[1]) : nil
        let day = dateFields.count > 2 ? Int(dateFields[2]) : nil
        var hour: Int?, minute: Int?, second: Int?
        if parts.count > 1 {
            let timeFields = parts[1].split(separator: ":").map { Int($0) }
            hour = timeFields.first ?? nil
            minute = timeFields.count > 1 ? timeFields[1] : nil
            second = timeFields.count > 2 ? timeFields[2] : nil
        }
        return WallClock(year: year, month: month, day: day, hour: hour, minute: minute, second: second, yearInferred: yearInferred)
    }
}
