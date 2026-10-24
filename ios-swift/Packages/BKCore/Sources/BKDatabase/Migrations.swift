/// 表结构迁移。版本号保存在 `PRAGMA user_version`。
///
/// 规则：
/// - 只追加新的迁移，不修改已发布的迁移；
/// - 每个迁移在一个事务里执行，失败整体回滚，版本号不变；
/// - 每次修改表结构都要在 `MigrationTests` 里补测试。
public enum Migrations {
    public static let latestVersion = 1

    static let steps: [(version: Int, sql: String)] = [
        (1, """
        CREATE TABLE accounts (
            id TEXT PRIMARY KEY NOT NULL,
            name TEXT NOT NULL,
            bank_id TEXT,
            bank_name TEXT NOT NULL,
            last4 TEXT NOT NULL CHECK (length(last4) = 4 AND last4 GLOB '[0-9][0-9][0-9][0-9]'),
            card_type TEXT NOT NULL,
            currency TEXT NOT NULL,
            palette_id TEXT NOT NULL,
            sort_order INTEGER NOT NULL,
            created_at REAL NOT NULL,
            archived INTEGER NOT NULL DEFAULT 0,
            last_success_at REAL,
            last_success_source TEXT,
            received_count INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX accounts_last4 ON accounts(last4);

        CREATE TABLE ingests (
            id TEXT PRIMARY KEY NOT NULL,
            fingerprint TEXT NOT NULL UNIQUE,
            source TEXT NOT NULL,
            sender TEXT,
            subject TEXT,
            received_at REAL,
            message_id TEXT,
            bound_account_id TEXT,
            processed_at REAL NOT NULL,
            raw_text TEXT,
            raw_purge_after REAL,
            classification TEXT NOT NULL,
            outcome TEXT NOT NULL,
            detail TEXT NOT NULL DEFAULT '',
            parser_version INTEGER NOT NULL
        );
        CREATE INDEX ingests_processed ON ingests(processed_at DESC);

        CREATE TABLE records (
            id TEXT PRIMARY KEY NOT NULL,
            account_id TEXT NOT NULL REFERENCES accounts(id),
            amount_minor INTEGER NOT NULL CHECK (amount_minor >= 0),
            currency TEXT NOT NULL,
            direction TEXT NOT NULL CHECK (direction IN ('inflow', 'outflow')),
            kind TEXT NOT NULL,
            status TEXT NOT NULL,
            counterparty TEXT,
            txn_time TEXT,
            txn_year_inferred INTEGER NOT NULL DEFAULT 0,
            received_at REAL,
            processed_at REAL NOT NULL,
            effective_at REAL NOT NULL,
            source TEXT NOT NULL,
            ingest_id TEXT NOT NULL REFERENCES ingests(id),
            part_index INTEGER NOT NULL,
            bank_reference TEXT,
            balance_after_minor INTEGER,
            included_fee_minor INTEGER,
            note TEXT NOT NULL DEFAULT '',
            transfer_group TEXT,
            related_record_id TEXT,
            dedupe_key TEXT NOT NULL UNIQUE,
            created_at REAL NOT NULL
        );
        CREATE INDEX records_effective ON records(effective_at DESC, id DESC);
        CREATE INDEX records_account ON records(account_id, effective_at DESC, id DESC);
        CREATE INDEX records_match ON records(amount_minor, currency, direction);

        CREATE TABLE record_evidence (
            record_id TEXT NOT NULL REFERENCES records(id),
            ingest_id TEXT NOT NULL REFERENCES ingests(id),
            source TEXT NOT NULL,
            added_at REAL NOT NULL,
            PRIMARY KEY (record_id, ingest_id)
        );

        CREATE TABLE balance_observations (
            id TEXT PRIMARY KEY NOT NULL,
            account_id TEXT NOT NULL REFERENCES accounts(id),
            amount_minor INTEGER NOT NULL,
            currency TEXT NOT NULL,
            order_key TEXT NOT NULL,
            txn_time TEXT,
            observed_at REAL NOT NULL,
            ingest_id TEXT NOT NULL REFERENCES ingests(id),
            record_id TEXT
        );
        CREATE INDEX balance_account ON balance_observations(account_id, order_key DESC);

        CREATE TABLE pending_items (
            id TEXT PRIMARY KEY NOT NULL,
            ingest_id TEXT NOT NULL REFERENCES ingests(id),
            part_index INTEGER NOT NULL,
            reason TEXT NOT NULL,
            draft_json TEXT,
            candidate_account_ids TEXT NOT NULL DEFAULT '',
            duplicate_of_record_id TEXT,
            status TEXT NOT NULL DEFAULT 'open',
            created_at REAL NOT NULL,
            resolved_at REAL,
            UNIQUE (ingest_id, part_index)
        );
        CREATE INDEX pending_status ON pending_items(status, created_at DESC);

        CREATE TABLE settings (
            key TEXT PRIMARY KEY NOT NULL,
            value TEXT NOT NULL
        );
        """),
    ]

    public static func migrate(_ connection: SQLiteConnection) throws {
        let current = connection.userVersion
        guard current < latestVersion else { return }
        for step in steps where step.version > current {
            try connection.immediateTransaction {
                try connection.execute(step.sql)
                try connection.setUserVersion(step.version)
            }
        }
    }
}
