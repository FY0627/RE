import Foundation
import XCTest
@testable import BKDatabase
import BKModel

final class DatabaseTests: XCTestCase {
    private func tempPath() -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bk-db-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("ledger.sqlite").path
    }

    private func account(_ last4: String, id: String = UUID().uuidString) -> Account {
        Account(id: id, name: "测试卡", bankID: "cmb", bankName: "招商银行", last4: last4, cardType: .debit, currency: .cny, paletteID: "ocean", sortOrder: 0, createdAt: Date(timeIntervalSince1970: 1_790_000_000))
    }

    func testMigrationCreatesSchemaAndIsIdempotent() throws {
        let path = tempPath()
        do {
            let db = try Database(path: path)
            XCTAssertEqual(try db.readSync { $0.userVersion }, Migrations.latestVersion)
        }
        // 重新打开不会重复执行迁移
        let reopened = try Database(path: path)
        XCTAssertEqual(try reopened.readSync { $0.userVersion }, Migrations.latestVersion)
        let tables = try reopened.readSync { db in
            try db.query("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name") { $0.string(0) }
        }
        for table in ["accounts", "balance_observations", "ingests", "pending_items", "record_evidence", "records", "settings"] {
            XCTAssertTrue(tables.contains(table), "missing table \(table)")
        }
    }

    func testMigrationFromVersion1KeepsAccountsAndAddsOpeningBalance() throws {
        let path = tempPath()
        do {
            // 模拟已经装了旧版本的账本：只有第 1 版表结构和一张卡
            let old = try SQLiteConnection(path: path)
            try old.execute(Migrations.steps[0].sql)
            try old.setUserVersion(1)
            try old.run(
                "INSERT INTO accounts (id, name, bank_id, bank_name, last4, card_type, currency, palette_id, sort_order, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                ["a1", "测试卡", "cmb", "招商银行", "0427", "debit", "CNY", "ocean", 0, Date(timeIntervalSince1970: 1_790_000_000)]
            )
        }
        let db = try Database(path: path)
        XCTAssertEqual(try db.readSync { $0.userVersion }, Migrations.latestVersion)
        let stored = try XCTUnwrap(try db.readSync { try AccountDAO.find($0, id: "a1") })
        XCTAssertEqual(stored.last4, "0427")
        XCTAssertNil(stored.openingBalanceMinor)
        let at = Date(timeIntervalSince1970: 1_790_000_100)
        XCTAssertTrue(try db.writeSync { try AccountDAO.setOpeningBalance($0, id: "a1", currency: .cny, amountMinor: -12_345, at: at) })
        let updated = try XCTUnwrap(try db.readSync { try AccountDAO.find($0, id: "a1") })
        XCTAssertEqual(updated.openingBalanceMinor, -12_345)
        XCTAssertEqual(updated.openingBalanceAt, at)
        XCTAssertTrue(try db.writeSync { try AccountDAO.setOpeningBalance($0, id: "a1", currency: .cny, amountMinor: nil, at: at) })
        let cleared = try XCTUnwrap(try db.readSync { try AccountDAO.find($0, id: "a1") })
        XCTAssertNil(cleared.openingBalanceMinor)
        XCTAssertNil(cleared.openingBalanceAt, "清除时时间一起清除")
    }

    func testMigrationFromVersion2AddsCardNumberAndFace() throws {
        let path = tempPath()
        do {
            let old = try SQLiteConnection(path: path)
            try old.execute(Migrations.steps[0].sql)
            try old.execute(Migrations.steps[1].sql)
            try old.setUserVersion(2)
            try old.run(
                "INSERT INTO accounts (id, name, bank_id, bank_name, last4, card_type, currency, palette_id, sort_order, created_at, opening_balance_minor) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                ["a1", "测试卡", "cmb", "招商银行", "0427", "debit", "CNY", "ocean", 0, Date(timeIntervalSince1970: 1_790_000_000), 5_000]
            )
        }
        let db = try Database(path: path)
        XCTAssertEqual(try db.readSync { $0.userVersion }, Migrations.latestVersion)
        let stored = try XCTUnwrap(try db.readSync { try AccountDAO.find($0, id: "a1") })
        XCTAssertEqual(stored.openingBalanceMinor, 5_000)
        XCTAssertNil(stored.cardNumber)
        XCTAssertEqual(stored.face, .standard, "旧卡使用默认卡面")

        let face = CardFace(imageID: "img-1", textColor: 0xFFEEDD, textScale: 1.2)
        XCTAssertTrue(try db.writeSync { try AccountDAO.updateFace($0, id: "a1", paletteID: "jade", face: face) })
        XCTAssertTrue(try db.writeSync { try AccountDAO.updateInfo($0, id: "a1", name: "工资卡", cardNumber: "6225880112340427") })
        let updated = try XCTUnwrap(try db.readSync { try AccountDAO.find($0, id: "a1") })
        XCTAssertEqual(updated.paletteID, "jade")
        XCTAssertEqual(updated.face, face)
        XCTAssertEqual(updated.name, "工资卡")
        XCTAssertEqual(updated.cardNumber, "6225880112340427")
    }

    func testMigrationFromVersion3MovesOpeningBalanceToPerCurrencyTable() throws {
        let path = tempPath()
        let at = Date(timeIntervalSince1970: 1_790_000_500)
        do {
            let old = try SQLiteConnection(path: path)
            for step in Migrations.steps where step.version <= 3 { try old.execute(step.sql) }
            try old.setUserVersion(3)
            try old.run(
                "INSERT INTO accounts (id, name, bank_id, bank_name, last4, card_type, currency, palette_id, sort_order, created_at, opening_balance_minor, opening_balance_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                ["a1", "测试卡", "cmb", "招商银行", "0427", "debit", "HKD", "ocean", 0, Date(timeIntervalSince1970: 1_790_000_000), -7_000, at]
            )
            try old.run(
                "INSERT INTO accounts (id, name, bank_id, bank_name, last4, card_type, currency, palette_id, sort_order, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                ["a2", "测试卡", "cmb", "招商银行", "0428", "debit", "CNY", "ocean", 1, Date(timeIntervalSince1970: 1_790_000_000)]
            )
        }
        let db = try Database(path: path)
        XCTAssertEqual(try db.readSync { $0.userVersion }, Migrations.latestVersion)
        let accounts = try db.readSync { try AccountDAO.all($0) }
        let first = try XCTUnwrap(accounts.first { $0.id == "a1" })
        XCTAssertEqual(first.extraCurrencies, [])
        XCTAssertEqual(first.openingBalances, [OpeningBalance(currency: .hkd, amountMinor: -7_000, at: at)])
        XCTAssertEqual(accounts.first { $0.id == "a2" }?.openingBalances, [])

        try db.writeSync { try AccountDAO.updateExtraCurrencies($0, id: "a1", primary: .hkd, extras: [.usd, .cny]) }
        XCTAssertTrue(try db.writeSync { try AccountDAO.setOpeningBalance($0, id: "a1", currency: .usd, amountMinor: 100, at: at) })
        XCTAssertFalse(try db.writeSync { try AccountDAO.setOpeningBalance($0, id: "missing", currency: .usd, amountMinor: 100, at: at) })
        let reloaded = try XCTUnwrap(try db.readSync { try AccountDAO.find($0, id: "a1") })
        XCTAssertEqual(reloaded.currencies, [.hkd, .usd, .cny])
        XCTAssertEqual(reloaded.openingBalance(.usd)?.amountMinor, 100)
        XCTAssertEqual(reloaded.openingBalanceMinor, -7_000, "主币种的初始余额")
    }

    func testLeadingZeroLast4SurvivesReopen() throws {
        let path = tempPath()
        do {
            let db = try Database(path: path)
            try db.writeSync { try AccountDAO.insert($0, account("0042", id: "a1")) }
        }
        let reopened = try Database(path: path)
        let stored = try reopened.readSync { try AccountDAO.find($0, id: "a1") }
        XCTAssertEqual(stored?.last4, "0042")
    }

    func testLast4ConstraintRejectsInvalidValues() throws {
        let db = try Database.inMemory()
        for invalid in ["123", "12345", "12a4"] {
            XCTAssertThrowsError(try db.writeSync { try AccountDAO.insert($0, account(invalid)) }, "accepted \(invalid)")
        }
    }

    func testFailedTransactionRollsBackCompletely() throws {
        let db = try Database.inMemory()
        struct Boom: Error {}
        XCTAssertThrowsError(try db.writeSync { conn in
            try AccountDAO.insert(conn, account("1111", id: "x"))
            throw Boom()
        })
        XCTAssertNil(try db.readSync { try AccountDAO.find($0, id: "x") })
    }

    func testWallClockCodecRoundTrip() {
        let clock = WallClock(year: 2026, month: 10, day: 4, hour: 9, minute: 5, second: nil)
        XCTAssertEqual(WallClockCodec.encode(clock), "2026-10-04T09:05")
        XCTAssertEqual(WallClockCodec.decode("2026-10-04T09:05", yearInferred: false), clock)
        let timeOnly = WallClock(year: nil, month: nil, day: nil, hour: 14, minute: 30)
        XCTAssertEqual(WallClockCodec.decode(WallClockCodec.encode(timeOnly), yearInferred: false)?.hour, 14)
    }
}
