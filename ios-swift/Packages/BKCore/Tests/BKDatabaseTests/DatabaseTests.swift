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
